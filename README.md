# Impianto chimico: miscelazione, trattamento termico e stoccaggio
SCADA didattico per la messa in servizio virtuale con OpenPLC (stesso schema dello scaldabagno).

```
impianto-chimico/
├── plc/impianto_chimico.st   programma di riferimento (ST, IEC 61131-3)
├── hmi/index.html            sinottico animato + modello fisico + guasti + PLC demo
└── bridge/                   ponte WebSocket ⇄ Modbus TCP (Python, uv)
    ├── bridge.py
    └── pyproject.toml
```

```
browser (index.html)  ⇄ WebSocket ⇄  bridge.py  ⇄ Modbus TCP ⇄  OpenPLC runtime (Docker)
  impianto simulato                  ogni 50 ms                    impianto_chimico.st
```

## Avvio rapido senza PLC
Apri `hmi/index.html` nel browser: in alto è selezionato **PLC demo interno**, un PLC in JavaScript che esegue
la stessa logica del file `.st`. Serve per vedere come deve comportarsi l'impianto prima di scrivere il programma.

## Con OpenPLC
1. **Editor**: nuovo progetto, crea il blocco funzione `TON_RIT` e il programma `impianto_chimico`
   copiando variabili e codice da `plc/impianto_chimico.st`; task ciclico a 20 ms. Compila e invia al runtime.
2. **Runtime**: abilita il server Modbus (porta 502). Nel container Docker la porta va pubblicata (`-p 502:502`).
   Servono almeno 10 registri `%MW` (default 1024) e 8 coil `%QX`.
3. **Bridge** (sul Mac mini):
   ```
   cd bridge
   uv run bridge.py --plc 127.0.0.1 --port 502
   ```
4. Apri **http://localhost:8080**, scegli **OpenPLC** in alto, poi **RESET** e **START**.

Al primo collegamento il PLC ha visto tutti gli ingressi a 0 (fungo e termico "aperti"),
quindi parte in emergenza: è corretto, basta premere RESET.

## Mappa I/O
Gli ingressi del campo arrivano nei registri di memoria `%MW` perché un client Modbus non può scrivere
nei `%IX` di OpenPLC. Il programma li copia subito in variabili BOOL (sezione 1): per passare a ingressi
`%IX` reali basta cambiare solo quella sezione.

| Ingresso | Indirizzo | Modbus | | Uscita | Indirizzo | Modbus |
|---|---|---|---|---|---|---|
| START (NA) | %MW0 | HR 1024 | | YV1 saracinesca | %QX0.0 | coil 0 |
| STOP (NC) | %MW1 | HR 1025 | | KM1 nastro panetti | %QX0.1 | coil 1 |
| EMERGENZA fungo (NC) | %MW2 | HR 1026 | | KM2 mescolatore 3~ | %QX0.2 | coil 2 |
| RESET (NA) | %MW3 | HR 1027 | | YV2 valvola scarico | %QX0.3 | coil 3 |
| SL livello max | %MW4 | HR 1028 | | KM3 rulliera casse | %QX0.4 | coil 4 |
| FC1 caduta panetto | %MW5 | HR 1029 | | H1 gialla (in funzione) | %QX0.5 | coil 5 |
| FC2 cassa sotto valvola | %MW6 | HR 1030 | | H2 verde (fermo) | %QX0.6 | coil 6 |
| FC3 cassa in magazzino | %MW7 | HR 1031 | | H3 rossa (emergenza/allarme) | %QX0.7 | coil 7 |
| FR termico M1 (NC) | %MW8 | HR 1032 | | riscaldatore 0–10000 mV | %QW0 | HR 0 |
| TT temperatura ×10 °C | %MW9 | HR 1033 | | K_SCALA | %QW1 | HR 1 |
| | | | | FASE · N_CASSE · COD_ALL · N_PANETTI | %QW2…5 | HR 2…5 |

`%QW1…5` non sono attuatori: servono allo SCADA. `K_SCALA` è obbligatorio, perché l'impianto simulato
lo legge per accelerare la propria dinamica in modo coerente con i timer del PLC.

## Dati dell'impianto simulato
- Tramoggia 80 L (bordo a 88 L: oltre trabocca), saracinesca 20 L/min, scarico 5 L/min → 20 L = 4 min.
- Panetti: uno ogni 2 s sul nastro; la fotocellula resta attiva almeno 250 ms per ogni panetto.
- Riscaldatore: temperatura di regime `T = 12·V` (minimo 20 °C ambiente), primo ordine con τ = 4 min.
  Il programma spinge a 10 V fino a 90 °C, poi tiene 7,5 V; lascia raffreddare a 0 V fino a 60 °C, poi tiene 5 V.
- **Scala dei tempi** `K_SCALA` (default 30: un lotto dura circa 5 minuti invece di 2 ore e mezza).
  Accelera tempi di processo, flussi e temperatura; nastro e rulliera restano alla velocità reale.

## Controllo qualità
Ogni cassa che entra in magazzino viene verificata: 20 ± 1 L, 5 panetti miscelati 5 min,
almeno 20 min a 90 °C, almeno 5 min a 60 °C, mai oltre 100 °C. Così gli studenti vedono subito
se il loro programma "funziona" ma produce scarti.

## Guasti simulati e risposta del programma di riferimento
| Guasto | Cosa succede | Rilevato da |
|---|---|---|
| Sensore livello bloccato OFF | trabocco della tramoggia | allarme 10 (watchdog riempimento) |
| Sensore livello bloccato ON | il ciclo non può partire | allarme 11 (controllo di plausibilità allo START) |
| Saracinesca bloccata chiusa | la tramoggia non si riempie | allarme 10 |
| Nastro inceppato / fotocellula accecata | i panetti non arrivano o non vengono contati | allarme 20 (dopo una fotocellula accecata entrano panetti in più) |
| Relè termico mescolatore | il motore si ferma | allarme 30 |
| Valvola di scarico bloccata chiusa | cassa vuota | **non rilevabile**: la cassa risulta non conforme (serve un sensore in più) |
| Valvola di scarico che perde | sversamento a terra | **non rilevabile** con questi sensori |
| Casse vuote esaurite | la rulliera gira a vuoto | allarme 40 |
| Resistenza interrotta | la temperatura non sale | allarme 60 |
| Sonda di temperatura interrotta | lettura −99,9 °C | allarme 70 |
| Operatore solleva la cassa durante lo scarico | se la valvola restasse aperta: sversamento | interblocco: la valvola chiude, il timer a ritenzione si ferma e riprende |

Dopo un guasto: elimina la causa, premi RESET, poi START. Il ciclo riprende dal punto in cui si era fermato.
RESET tenuto premuto 3 s a impianto fermo azzera il ciclo.

## Note
- Tieni la pagina visibile: i browser sospendono le schede in secondo piano. Se il bridge non riceve
  dati dal browser per 2 s, invia al PLC STOP premuto per sicurezza.
- Con `K_SCALA` alto si vede la latenza Modbus: il sensore di livello commuta a 80 L ma la saracinesca
  chiude con un po' di ritardo, quindi in tramoggia entrano 1–2 L in più. È un buon spunto di discussione.

## Collaudo eseguito
- Il file `.st` è stato compilato con il compilatore di OpenPLC (matiec `iec2c`) e poi con gcc.
- Il programma compilato è stato eseguito come PLC software dietro un server Modbus con la mappa di OpenPLC,
  collegato a `bridge.py` e alla pagina: lotto completo, 4 casse conformi.
- Guasti, emergenza, pausa durante il mantenimento a 90 °C e sollevamento della cassa durante lo scarico
  sono stati provati con il PLC demo.
- Non è stato provato con l'Editor e il runtime v4 veri: controlla in particolare le dimensioni dei
  segmenti del server Modbus (`%MW`, `%QX`).

## Licenza

© 2026 Prof. Di Filippo Davide.

- **Codice** (programma ST, bridge Python, JavaScript, CSS e struttura HTML):
  [GNU GPL versione 3 o successiva](LICENSE). Le versioni modificate e ridistribuite devono restare sotto GPL.
- **Contenuti didattici** (testi, consegne, dati dell'impianto, tabelle, figure): [Creative Commons
  Attribuzione - Condividi allo stesso modo 4.0 Internazionale (CC BY-SA 4.0)](LICENSE-CONTENUTI).

**Termine aggiuntivo (GPLv3, sezione 7b):** le versioni modificate devono mantenere visibile
nelle pagine la dicitura "Autore originale: Prof. Di Filippo Davide".
