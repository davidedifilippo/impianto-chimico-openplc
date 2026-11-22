(* =====================================================================
   IMPIANTO CHIMICO - PREPARAZIONE, TRATTAMENTO TERMICO E STOCCAGGIO
   Programma per OpenPLC (IEC 61131-3, Structured Text)
   Autore: Prof. Di Filippo Davide
   Licenza: GNU GPL v3 o successiva (SPDX: GPL-3.0-or-later), vedi LICENSE.
   Termine aggiuntivo (GPLv3, sez. 7b): le versioni modificate devono mantenere
   la dicitura "Autore originale: Prof. Di Filippo Davide".

   Ciclo di un lotto:
     10 RIEMPIMENTO   saracinesca aperta fino al livello massimo (80 L)
     20 PANETTI       nastro in marcia fino alla caduta del 5° panetto
     30 MESCOLAZIONE  mescolatore trifase per 5 minuti
     per ciascuna delle 4 casse:
       40 ARRIVO CASSA  rulliera in marcia finché la cassa è sotto la valvola
       50 SCARICO       valvola aperta 4 min (20 L a 5 L/min), solo con cassa presente
       60 RISCALDO      riscaldatore a 10 V fino a 90 °C
       70 MANTIENI 90   7,5 V (T = 12*V) per 20 minuti
       80 RAFFREDDO     0 V fino a 60 °C
       90 MANTIENI 60   5 V per 5 minuti
      100 STOCCAGGIO    rulliera in marcia finché la cassa entra in magazzino
    110 FINE          4 casse stoccate: composto terminato

   Comandi:   START (NA), STOP (NC), RESET (NA), EMERGENZA a fungo (NC)
              RESET tenuto premuto 3 s a impianto fermo = azzera il ciclo
   Lampade:   gialla = in funzione, verde = fermo,
              rossa fissa = emergenza, rossa lampeggiante = allarme/guasto

   SCALA DEI TEMPI: K_SCALA accelera tutto il processo (tempi del PLC e
   dinamica dell'impianto simulato, che legge K_SCALA da %QW1).
   K_SCALA = 1 -> tempo reale (circa 2 ore e mezza per un lotto).
   I movimenti meccanici (nastro, rulliera) NON sono accelerati.
   ===================================================================== *)


(* ---------------------------------------------------------------------
   Temporizzatore a ritenzione (TONR): conta solo mentre IN = TRUE e
   conserva il tempo accumulato quando IN torna FALSE (pausa, STOP,
   emergenza, cassa tolta durante lo scarico). Si azzera con RST.
   --------------------------------------------------------------------- *)
FUNCTION_BLOCK TON_RIT
  VAR_INPUT
    IN  : BOOL;
    PT  : TIME;
    RST : BOOL;
  END_VAR
  VAR_OUTPUT
    Q  : BOOL;
    ET : TIME;
  END_VAR
  VAR
    tmr    : TON;
    acc    : TIME := T#0s;
    in_old : BOOL;
  END_VAR

  IF RST THEN
    acc := T#0s;
    tmr(IN := FALSE, PT := PT);
    in_old := FALSE;
  ELSE
    (* fronte di discesa: salvo il tempo contato fino ad ora *)
    IF in_old AND NOT IN THEN
      acc := acc + tmr.ET;
    END_IF;
    IF acc < PT THEN
      tmr(IN := IN, PT := PT - acc);
    ELSE
      tmr(IN := FALSE, PT := T#0s);
    END_IF;
    in_old := IN;
  END_IF;

  ET := acc + tmr.ET;
  Q  := ET >= PT;
END_FUNCTION_BLOCK


PROGRAM impianto_chimico
  (* ====================== INGRESSI (dal campo) ======================
     Scritti dal simulatore via Modbus nei registri di memoria %MW
     (holding register 1024 e seguenti). Valore 0/1 per i digitali.   *)
  VAR
    I_START     AT %MW0 : INT;  (* pulsante START, NA                  *)
    I_STOP      AT %MW1 : INT;  (* pulsante STOP, NC (1 = non premuto) *)
    I_EMERG     AT %MW2 : INT;  (* fungo emergenza, NC (1 = rilasciato)*)
    I_RESET     AT %MW3 : INT;  (* pulsante RESET, NA                  *)
    I_SL_MAX    AT %MW4 : INT;  (* sensore livello massimo tramoggia   *)
    I_FC_PAN    AT %MW5 : INT;  (* fotocellula caduta panetto          *)
    I_FC_CASSA  AT %MW6 : INT;  (* cassa presente sotto la valvola     *)
    I_FC_MAG    AT %MW7 : INT;  (* cassa entrata in magazzino          *)
    I_FR_MESC   AT %MW8 : INT;  (* relè termico mescolatore, NC (1=OK) *)
    I_TT        AT %MW9 : INT;  (* temperatura cassa in decimi di °C   *)
  END_VAR

  (* ====================== USCITE (verso il campo) =================== *)
  VAR
    YV_MANDATA  AT %QX0.0 : BOOL;  (* saracinesca di mandata liquido   *)
    KM_NASTRO   AT %QX0.1 : BOOL;  (* motore nastro panetti            *)
    KM_MESC     AT %QX0.2 : BOOL;  (* contattore mescolatore trifase   *)
    YV_SCARICO  AT %QX0.3 : BOOL;  (* elettrovalvola di scarico        *)
    KM_RULLIERA AT %QX0.4 : BOOL;  (* motore rulliera casse            *)
    HL_GIALLA   AT %QX0.5 : BOOL;  (* impianto in funzione             *)
    HL_VERDE    AT %QX0.6 : BOOL;  (* impianto fermo                   *)
    HL_ROSSA    AT %QX0.7 : BOOL;  (* emergenza / allarme              *)

    AO_RISC     AT %QW0 : INT;     (* riscaldatore 0..10000 mV         *)
    K_SCALA     AT %QW1 : INT := 30; (* accelerazione dei tempi        *)
    FASE        AT %QW2 : INT;     (* passo della sequenza (per HMI)   *)
    N_CASSE     AT %QW3 : INT;     (* casse stoccate                   *)
    COD_ALL     AT %QW4 : INT;     (* codice allarme (0 = nessuno)     *)
    N_PANETTI   AT %QW5 : INT;     (* panetti caricati                 *)
  END_VAR

  (* ====================== PARAMETRI ================================= *)
  VAR CONSTANT
    N_PANETTI_LOTTO : INT  := 5;
    N_CASSE_LOTTO   : INT  := 4;
    SP_ALTA         : REAL := 90.0;   (* °C *)
    SP_BASSA        : REAL := 60.0;   (* °C *)
    V_MAX           : REAL := 10.0;   (* V  *)
    K_RISC          : REAL := 12.0;   (* °C/V : Temp = 12 * Volt *)

    T_MESCOLA  : TIME := T#5m;
    T_SCARICO  : TIME := T#4m;    (* 20 L / (5 L/min) = 4 min *)
    T_MANT_90  : TIME := T#20m;
    T_MANT_60  : TIME := T#5m;

    (* tempi massimi (watchdog): oltre questi c'è un guasto *)
    WD_RIEMPI  : TIME := T#5m;    (* nominale 4 min (20 L/min)  *)
    WD_PANETTI : TIME := T#30s;   (* nominale circa 10 s - NON scalato *)
    WD_CASSA   : TIME := T#20s;   (* nominale circa 4 s  - NON scalato *)
    WD_RISC    : TIME := T#10m;   (* nominale circa 5 min       *)
    WD_RAFF    : TIME := T#6m;    (* nominale circa 2 min       *)
  END_VAR

  (* ====================== VARIABILI INTERNE ========================= *)
  VAR
    START, STOP_OK, EMERG_OK, RESET : BOOL;
    SL_MAX, FC_PAN, FC_CASSA, FC_MAG, FR_OK : BOOL;
    TEMP : REAL;

    MARCIA    : BOOL;          (* ciclo avviato dall'operatore      *)
    EMERGENZA : BOOL;          (* memoria di emergenza              *)
    ALLARME   : BOOL;          (* memoria di allarme                *)
    ATTIVO    : BOOL;          (* MARCIA e nessun blocco            *)
    TENSIONE  : REAL;          (* volt al riscaldatore              *)

    FT_START : R_TRIG;
    FT_RESET : R_TRIG;
    FT_PAN   : R_TRIG;
    FT_MAG   : R_TRIG;
    T_RESET_LUNGO : TON;

    TR_MESCOLA : TON_RIT;
    TR_SCARICO : TON_RIT;
    TR_MANT90  : TON_RIT;
    TR_MANT60  : TON_RIT;
    WD : TON;                  (* watchdog del passo attivo         *)
    WD_PT : TIME;
    FASE_OLD : INT;

    LAMP_A : TON;              (* oscillatore 1 Hz per la rossa     *)
    LAMP_B : TON;
    LAMP : BOOL;
  END_VAR

  (* ================= 1. LETTURA E NORMALIZZAZIONE INGRESSI ========= *)
  START    := I_START    <> 0;
  STOP_OK  := I_STOP     <> 0;
  EMERG_OK := I_EMERG    <> 0;
  RESET    := I_RESET    <> 0;
  SL_MAX   := I_SL_MAX   <> 0;
  FC_PAN   := I_FC_PAN   <> 0;
  FC_CASSA := I_FC_CASSA <> 0;
  FC_MAG   := I_FC_MAG   <> 0;
  FR_OK    := I_FR_MESC  <> 0;
  TEMP     := INT_TO_REAL(I_TT) / 10.0;

  IF K_SCALA < 1 THEN K_SCALA := 1; END_IF;

  FT_START(CLK := START);
  FT_RESET(CLK := RESET);
  FT_PAN(CLK := FC_PAN);
  FT_MAG(CLK := FC_MAG);

  (* ================= 2. EMERGENZA, ALLARMI, MARCIA/ARRESTO ========= *)
  IF NOT EMERG_OK THEN
    EMERGENZA := TRUE;
    MARCIA := FALSE;
  END_IF;

  (* guasti rilevati in qualsiasi momento *)
  IF NOT FR_OK THEN
    ALLARME := TRUE; COD_ALL := 30;          (* termico mescolatore *)
  END_IF;
  IF (TEMP < -50.0) OR (TEMP > 200.0) THEN
    ALLARME := TRUE; COD_ALL := 70;          (* sonda temperatura   *)
  END_IF;

  (* RESET: tacita emergenza (solo a fungo sbloccato) e allarmi *)
  IF FT_RESET.Q AND EMERG_OK THEN
    EMERGENZA := FALSE;
    ALLARME := FALSE;
    COD_ALL := 0;
  END_IF;

  IF NOT STOP_OK THEN
    MARCIA := FALSE;
  END_IF;

  IF FT_START.Q AND STOP_OK AND NOT EMERGENZA AND NOT ALLARME THEN
    IF (FASE = 0) OR (FASE = 110) THEN
      IF SL_MAX THEN
        (* tramoggia "piena" prima di riempirla: sensore incoerente *)
        ALLARME := TRUE; COD_ALL := 11;
      ELSE
        FASE := 10;           (* nuovo lotto *)
        N_CASSE := 0;
        N_PANETTI := 0;
        MARCIA := TRUE;
      END_IF;
    ELSE
      MARCIA := TRUE;         (* ripresa dal punto in cui si era fermato *)
    END_IF;
  END_IF;

  (* RESET tenuto 3 s a impianto fermo: azzera il ciclo *)
  T_RESET_LUNGO(IN := RESET AND NOT MARCIA, PT := T#3s);
  IF T_RESET_LUNGO.Q THEN
    FASE := 0; N_CASSE := 0; N_PANETTI := 0;
  END_IF;

  IF EMERGENZA OR ALLARME THEN
    MARCIA := FALSE;
  END_IF;
  ATTIVO := MARCIA;

  (* ================= 3. SEQUENZA =================================== *)
  (* temporizzatori di processo (a ritenzione) *)
  TR_MESCOLA(IN := ATTIVO AND (FASE = 30), PT := T_MESCOLA / K_SCALA,
             RST := (FASE <> 30));
  TR_SCARICO(IN := ATTIVO AND (FASE = 50) AND FC_CASSA,
             PT := T_SCARICO / K_SCALA, RST := (FASE <> 50));
  (* il mantenimento conta solo se la temperatura è davvero quella
     richiesta: dopo una pausa la cassa si è raffreddata e va riscaldata *)
  TR_MANT90(IN := ATTIVO AND (FASE = 70) AND (TEMP >= SP_ALTA - 2.0),
            PT := T_MANT_90 / K_SCALA, RST := (FASE <> 70));
  TR_MANT60(IN := ATTIVO AND (FASE = 90) AND (TEMP >= SP_BASSA - 2.0)
            AND (TEMP <= SP_BASSA + 2.0),
            PT := T_MANT_60 / K_SCALA, RST := (FASE <> 90));

  IF ATTIVO THEN
    CASE FASE OF
      10: (* riempimento *)
          IF SL_MAX THEN FASE := 20; END_IF;

      20: (* carico panetti *)
          IF FT_PAN.Q THEN N_PANETTI := N_PANETTI + 1; END_IF;
          IF N_PANETTI >= N_PANETTI_LOTTO THEN FASE := 30; END_IF;

      30: (* mescolazione *)
          IF TR_MESCOLA.Q THEN FASE := 40; END_IF;

      40: (* arrivo cassa sotto la valvola *)
          IF FC_CASSA THEN FASE := 50; END_IF;

      50: (* scarico 20 L *)
          IF TR_SCARICO.Q THEN FASE := 60; END_IF;

      60: (* riscaldamento fino a 90 °C *)
          IF TEMP >= SP_ALTA THEN FASE := 70; END_IF;

      70: (* mantenimento 90 °C *)
          IF TR_MANT90.Q THEN FASE := 80; END_IF;

      80: (* raffreddamento fino a 60 °C *)
          IF TEMP <= SP_BASSA THEN FASE := 90; END_IF;

      90: (* mantenimento 60 °C *)
          IF TR_MANT60.Q THEN FASE := 100; END_IF;

      100: (* stoccaggio: la cassa va in magazzino *)
          IF FT_MAG.Q THEN
            N_CASSE := N_CASSE + 1;
            IF N_CASSE >= N_CASSE_LOTTO THEN
              FASE := 110;
              MARCIA := FALSE;  (* composto terminato *)
              ATTIVO := FALSE;
            ELSE
              FASE := 40;
            END_IF;
          END_IF;
    END_CASE;
  END_IF;

  (* ================= 4. WATCHDOG (tempo massimo per passo) ========= *)
  (* i tempi di processo si scalano con K_SCALA, i movimenti meccanici
     (nastro, rulliera) no: nel simulatore hanno velocità reale *)
  CASE FASE OF
    10:  WD_PT := WD_RIEMPI / K_SCALA;
    20:  WD_PT := WD_PANETTI;
    40:  WD_PT := WD_CASSA;
    60:  WD_PT := WD_RISC / K_SCALA;
    80:  WD_PT := WD_RAFF / K_SCALA;
    100: WD_PT := WD_CASSA;
  ELSE
    WD_PT := T#0s;
  END_CASE;
  WD(IN := ATTIVO AND (WD_PT > T#0s) AND (FASE = FASE_OLD), PT := WD_PT);
  IF WD.Q THEN
    ALLARME := TRUE;
    COD_ALL := FASE;      (* 10, 20, 40, 60, 80, 100: timeout del passo *)
    MARCIA := FALSE;
    ATTIVO := FALSE;
  END_IF;
  FASE_OLD := FASE;

  (* ================= 5. USCITE ===================================== *)
  YV_MANDATA  := ATTIVO AND (FASE = 10);
  KM_NASTRO   := ATTIVO AND (FASE = 20);
  KM_MESC     := ATTIVO AND (FASE = 30) AND FR_OK;
  YV_SCARICO  := ATTIVO AND (FASE = 50) AND FC_CASSA;   (* interblocco *)
  KM_RULLIERA := ATTIVO AND (((FASE = 40) AND NOT FC_CASSA) OR (FASE = 100));

  (* riscaldatore: Temp = 12 * Volt  ->  Volt = Temp / 12 *)
  TENSIONE := 0.0;
  IF ATTIVO THEN
    CASE FASE OF
      60: TENSIONE := V_MAX;                 (* spinta: verso 120 °C     *)
      70: IF TEMP < SP_ALTA - 1.0 THEN
            TENSIONE := V_MAX;               (* recupero dopo una pausa  *)
          ELSE
            TENSIONE := SP_ALTA / K_RISC;    (* 7,5 V -> 90 °C a regime  *)
          END_IF;
      80: TENSIONE := 0.0;                   (* raffreddamento naturale  *)
      90: IF TEMP < SP_BASSA - 1.0 THEN
            TENSIONE := V_MAX;
          ELSE
            TENSIONE := SP_BASSA / K_RISC;   (* 5 V   -> 60 °C a regime  *)
          END_IF;
    END_CASE;
  END_IF;
  AO_RISC := REAL_TO_INT(TENSIONE * 1000.0);

  (* lampade *)
  LAMP_A(IN := NOT LAMP_B.Q, PT := T#500ms);
  LAMP_B(IN := LAMP_A.Q, PT := T#500ms);
  LAMP := LAMP_A.Q;

  HL_GIALLA := MARCIA AND NOT EMERGENZA AND NOT ALLARME;
  HL_VERDE  := NOT MARCIA AND NOT EMERGENZA AND NOT ALLARME;
  HL_ROSSA  := EMERGENZA OR (ALLARME AND LAMP);
END_PROGRAM


CONFIGURATION Config0
  RESOURCE Res0 ON PLC
    TASK TaskMain(INTERVAL := T#20ms, PRIORITY := 0);
    PROGRAM Inst0 WITH TaskMain : impianto_chimico;
  END_RESOURCE
END_CONFIGURATION
