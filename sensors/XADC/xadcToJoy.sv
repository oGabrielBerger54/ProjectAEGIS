`timescale 1ns / 1ps

// O QUE ESTE MÓDULO FAZ
//  É a ponte entre o xadcReader e o joyToTarget.
//  O xadcReader entrega números de 0 a 4095 (o centro do joystick cai perto de 1690).
//  O joyToTarget espera números de 0 a 1023 com o centro em 512.
//  Este módulo faz essa conversão, FILTRA o tremido e também gera o pulso "chegou leitura nova" (~95 vezes por segundo).

// COMO FUNCIONA (5 passos)
//  1) SINCRONIZAR: o xadcReader roda no clock de 100 MHz e este módulo no de 25 MHz. O valor passa por 2 registradores e só é aceito se
//     duas leituras seguidas forem iguais (evita pegar um número "pela metade" no instante em que ele muda).
//  1b) FILTRAR (tira o tremido), em duas etapas:
//     - MÉDIA: em vez de pegar UMA leitura a cada 10 ms, soma o valor em todos os 2^18 ciclos (~10,5 ms) e divide por 2^18
//       (dividir por potência de 2 = só pegar os bits de cima). Ruído rápido some na média.
//     - SUAVIZAÇÃO (média móvel exponencial): a cada média nova, o valor filtrado anda 1/2^FILTER_SHIFT do caminho até ela.
//       Com FILTER_SHIFT = 2 (1/4), a mira leva ~40 ms para chegar na posição: tira o tremido sem ficar "pesada".
//       Ainda tremendo? Suba para 3 (mais liso, ~85 ms). Muito lenta? Baixe para 1.
//  2) CALIBRAR O CENTRO: logo depois de ligar (ou do reset), espera ~0,5 s e depois tira a média de 64 leituras (~0,64 s).
//     Essa média é o "centro" do seu joystick. POR ISSO: NÃO MEXA NO JOYSTICK ao ligar a placa ou apertar o reset.
//  3) CONVERTER: diferença = leitura - centro. Multiplica por GAIN_NUM/16 e soma 512. Limita entre 0 e 1023.
//  4) AVISAR: a cada ~10,5 ms (depois de calibrado) dá um pulso de 1 ciclo em joyValid.

module xadcToJoy #(
    // Ganho = GAIN_NUM / 16. Com 5, o ganho é 0,3125: o joystick todo para um lado (~1690 de diferença) vira ~528, e o limite corta em 511.
    parameter int GAIN_NUM = 5,

    parameter int SETTLE_READS = 50, // leituras ignoradas antes de calibrar (50 x 10,5 ms = ~0,5 s; dá tempo do filtro assentar)
    parameter int CAL_LOG2 = 6, // a média do centro usa 2^6 = 64 leituras

    parameter int AVG_LOG2 = 18, // a média usa 2^18 ciclos de 25 MHz = ~10,5 ms (é também o intervalo entre leituras: ~95 por segundo)
    parameter int FILTER_SHIFT = 2 // suavização: anda 1/4 do caminho a cada leitura. Maior = mais liso e mais lento
)(
    input logic clk, // clock de 25 MHz
    input logic rst_n, // reset, ativo em 0
    input logic [11:0] xRaw, // eixo X vindo do xadcReader (0 a 4095)
    input logic [11:0] yRaw, // eixo Y vindo do xadcReader (0 a 4095)

    output logic [9:0] joyX, // 0 a 1023, centro em 512
    output logic [9:0] joyY, // 0 a 1023, centro em 512
    output logic joyValid, // pulso de 1 ciclo: "chegou leitura nova"
    output logic calibrated // 1 = centro já calibrado
);

// PASSO 1 - SINCRONIZAR (clock de 100 MHz -> 25 MHz)
logic [11:0] xS1, xS2, yS1, yS2;
logic [11:0] xStable, yStable;

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        xS1 <= '0; xS2 <= '0; yS1 <= '0; yS2 <= '0;
        xStable <= '0; yStable <= '0;
    end else begin
        xS1 <= xRaw; xS2 <= xS1;
        yS1 <= yRaw; yS2 <= yS1;
        if(xS1 == xS2) xStable <= xS2;
        if(yS1 == yS2) yStable <= yS2;
    end
end

// PASSO 1b - FILTRAR
// Média: soma xStable em todos os ciclos da janela. No fim da janela (tick), média = soma / 2^AVG_LOG2.
logic [AVG_LOG2 - 1:0] tickCnt;
logic tick;
logic [AVG_LOG2 + 11:0] accX, accY; // somas da janela
logic [11:0] avgX, avgY; // média da última janela (0 a 4095)

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        tickCnt <= '0;
        tick <= 1'b0;
        accX <= '0;
        accY <= '0;
        avgX <= 12'd1690;
        avgY <= 12'd1690;
    end else begin
        tickCnt <= tickCnt + 1'b1; // volta sozinho para 0 depois de 2^AVG_LOG2 ciclos
        if(&tickCnt) begin // último ciclo da janela
            avgX <= 12'((accX + xStable) >> AVG_LOG2);
            avgY <= 12'((accY + yStable) >> AVG_LOG2);
            accX <= '0;
            accY <= '0;
            tick <= 1'b1;
        end else begin
            accX <= accX + xStable;
            accY <= accY + yStable;
            tick <= 1'b0;
        end
    end
end

// Suavização: filt guarda o valor com 4 bits de fração (x16), para os passos pequenos não se perderem no arredondamento.
// Roda 1 ciclo depois do tick (avg já atualizado); o resto do módulo usa o valor no tick seguinte.
logic [15:0] filtX, filtY; // valor filtrado x 16
logic signed [17:0] stepX, stepY;
logic [11:0] xFilt, yFilt; // valor filtrado (0 a 4095): é o que o resto do módulo usa

always_comb begin
    stepX = ($signed({2'b00, avgX, 4'b0}) - $signed({2'b00, filtX})) >>> FILTER_SHIFT;
    stepY = ($signed({2'b00, avgY, 4'b0}) - $signed({2'b00, filtY})) >>> FILTER_SHIFT;
end

logic tickD; // tick atrasado 1 ciclo
always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        tickD <= 1'b0;
        filtX <= {12'd1690, 4'b0};
        filtY <= {12'd1690, 4'b0};
    end else begin
        tickD <= tick;
        if(tickD) begin
            filtX <= 16'($signed({2'b00, filtX}) + stepX);
            filtY <= 16'($signed({2'b00, filtY}) + stepY);
        end
    end
end

assign xFilt = filtX[15:4];
assign yFilt = filtY[15:4];

// PASSO 2 - CALIBRAR O CENTRO (já com o valor filtrado)
typedef enum logic [1:0] {SETTLE, CAL, RUN} state_t;
state_t state;

logic [8:0] cnt;
logic [CAL_LOG2 + 11:0] sumX, sumY;
logic [CAL_LOG2 + 11:0] nextSumX, nextSumY;
logic [11:0] centerX, centerY;

assign nextSumX = sumX + {{CAL_LOG2{1'b0}}, xFilt};
assign nextSumY = sumY + {{CAL_LOG2{1'b0}}, yFilt};

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state <= SETTLE;
        cnt <= '0;
        sumX <= '0;
        sumY <= '0;
        centerX <= 12'd1690;
        centerY <= 12'd1690;
    end else if(tick) begin
        case(state)
            SETTLE: begin
                if(cnt == SETTLE_READS - 1) begin
                    cnt <= '0;
                    sumX <= '0;
                    sumY <= '0;
                    state <= CAL;
                end else cnt <= cnt + 1'b1;
            end
            CAL: begin
                sumX <= nextSumX;
                sumY <= nextSumY;
                if(cnt == (1 << CAL_LOG2) - 1) begin
                    centerX <= nextSumX[CAL_LOG2 + 11:CAL_LOG2];
                    centerY <= nextSumY[CAL_LOG2 + 11:CAL_LOG2];
                    state <= RUN;
                end else cnt <= cnt + 1'b1;
            end
            default: ;
        endcase
    end
end

assign calibrated = (state == RUN);

// PASSO 3 - CONVERTER
logic signed [13:0] diffX, diffY; // distancias do  centro
logic signed [31:0] valX, valY;

always_comb begin
    diffX = $signed({2'b00, xFilt}) - $signed({2'b00, centerX});
    diffY = $signed({2'b00, yFilt}) - $signed({2'b00, centerY});
    valX = 32'sd512 + ((32'(diffX) * GAIN_NUM) >>> 4);
    valY = 32'sd512 + ((32'(diffY) * GAIN_NUM) >>> 4);
end

function automatic logic [9:0] clamp10(input logic signed [31:0] v);
    if(v < 0) return 10'd0;
    else if(v > 1023) return 10'd1023;
    else return v[9:0];
endfunction

// PASSO 4 - AVISAR
always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        joyX <= 10'd512;
        joyY <= 10'd512;
        joyValid <= 1'b0;
    end else begin
        joyValid <= tick && (state == RUN);
        if(state == RUN) begin
            joyX <= clamp10(valX);
            joyY <= clamp10(valY);
        end else begin
            joyX <= 10'd512;
            joyY <= 10'd512;
        end
    end
end

endmodule
