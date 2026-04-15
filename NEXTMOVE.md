# NEXTMOVE

## Stato rapido

- Branch/workspace: ci sono modifiche locali non ancora compilate/deployate dopo `r0014`.
- Obiettivo corrente: chiudere il bug dei probe `healthy` e il blocco di `POST /api/fetch`.
- Server target: `pb.yafb.net`
- Deploy richiesto dal progetto: `make deploy`

## Problemi confermati

### 1. `/api/fetch` resta appesa troppo a lungo

Causa trovata in `src/main.zig`:

- `handleFetch()` dopo `performFetch()` chiamava ancora `refreshPackageInfoSnapshot(...)`
- quel refresh faceva probe su **tutti** i package
- quindi la fetch restava aperta anche se i tarball erano già stati creati

Effetto pratico visto su `pb.yafb.net`:

- `mush-demo` crea i tarball subito
- la request HTTP resta aperta mentre parte il giro globale di probe

### 2. Tutti o quasi i package diventano `healthy=false`

Cause trovate:

- il probe storico usava `zig fetch`, ma nel container remoto `zig` non c'è:
  `sh: zig: not found`
- la readiness del helper usava `/api/status`, che è fragile perché legge file JSON di stato che durante update possono essere visti in stato transitorio
- i file di stato in `src/sync.zig` sono scritti con `truncate + write`, quindi non in modo atomico

Sintomo osservato nei log remoti:

- molti `curl: (52) Empty reply from server`
- almeno una volta: `warning: request failed: SyntaxError`

Interpretazione:

- il helper parte, ma la sua readiness su `/api/status` è accoppiata a file di stato che possono risultare temporaneamente incoerenti
- anche se la readiness passasse, il probe con `zig fetch` nel container è comunque sbagliato

## Modifiche locali già applicate

### `src/main.zig`

Ho già patchato localmente:

- import di `src/git.zig`
- `handleFetch()` ora chiama:
  `refreshPackageInfoSnapshot(..., true)`
- `updateWorker()` ora chiama:
  `refreshPackageInfoSnapshot(..., false)`
- `refreshPackageInfoSnapshot()` ha un nuovo parametro:
  `preserve_probes: bool`
- quando `preserve_probes=true`:
  - aggiorna lo snapshot
  - preserva i probe precedenti
  - non rilancia probe globali
- `validatePseudoGitFetchability()` non usa più `zig fetch`
- il nuovo probe usa `git_proto.Session.init(...)` + `listRefs(...)`
- il probe verifica il server pseudo-git con primitive low-level del file `src/git.zig`

Questo allinea il probe alla richiesta architetturale: niente shell Git e niente dipendenza da `zig fetch`.

## Modifiche ancora da fare

### `src/sync.zig`

Serve ancora una patch importante:

- rendere atomiche le scritture di stato

Funzioni da sistemare:

- `writeTextFile`
- `writeIntFile`

Approccio consigliato:

- scrivere su file temporaneo nella stessa directory
- `fsync` opzionale se vuoi essere più rigoroso
- `rename` atomica sul path finale

Motivo:

- così eviti JSON troncati durante:
  - `update.status.json`
  - `package-info.json`
  - manifest e altri file scritti da `writeTextFile`

## Verifiche già fatte

### Helper remoto dentro il container

Comando provato via `docker compose exec`:

- `/usr/local/bin/packbase` parte correttamente sul helper port
- `curl http://127.0.0.1:19082/api/status` può rispondere correttamente

Quindi:

- il problema non è il bind della porta
- il problema è la combinazione di probe vecchio + stato non atomico + fetch globale

### Probe storico con `zig`

Riproduzione remota:

- `zig fetch --save git+http://127.0.0.1:19082/httpz.zig`
- esito: `sh: zig: not found`

Questo conferma che il vecchio probe non può essere affidabile nel container attuale.

## Checklist per riprendere

1. Patchare `src/sync.zig` con scritture atomiche.
2. Eseguire build/test locale:
   - `zig build`
3. Deploy:
   - `make deploy`
4. Verificare remoto:
   - `curl -fsS https://pb.yafb.net/api/status`
   - controllare che `packages_healthy` torni coerente
5. Verificare fetch reale:
   - `curl -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer p4J3ect4SPSxKzXZZgSYXeWnV7H3YtjK' --data '{"url":"https://github.com/francescobianco/mush-demo"}' 'https://pb.yafb.net/api/fetch'`
6. Verificare che la fetch risponda subito e non resti appesa dopo la creazione dei tarball.
7. Controllare logs remoti:
   - sparizione di `curl: (52) Empty reply from server`
   - sparizione di `SyntaxError` durante i probe

## File toccati in questo ultimo step

- `src/main.zig`
- `NEXTMOVE.md`

## Nota finale

Il fix logico più importante è già in workspace:

- `fetch` non deve più comportarsi come una mini-`update` globale
- il probe healthy deve vivere sulle primitive di `src/git.zig`, non su `zig fetch`

Resta da chiudere bene la parte di persistenza atomica in `src/sync.zig`, poi build, deploy e verifica finale su `pb.yafb.net`.
