# factory-kit

El kit de la fábrica para el taller "Software factories with Claude Code". Esta página es para
quienes **organizan** el taller y mantienen los repos de problemas. Los participantes no usan este
repo: usan los repos de problemas, que ya traen el kit instalado con `sync.sh`.

Diseño completo y planes: el repo privado `sgomezahumada/factory-workshop-notes`.
Lo que lee el tablero de la sala: `docs/run-contract.md` (pásaselo a quien construye el tablero).

## Qué hay aquí

| Ruta | Qué es |
|---|---|
| `kit/factory.sh`, `kit/lib/` | el motor: cuatro sesiones nuevas de `claude -p`, archivos de contrato, scope, gates, PR desde el fork |
| `kit/lib/telemetry.sh` | cliente de telemetría para el tablero de la sala (copia de `client/telemetry.sh` de Emer-42/demo-factory-dashboard); apagado salvo que `FACTORY_TELEMETRY_URL` esté definida, ver `docs/run-contract.md` |
| `kit/doctor.sh` | revisa la laptop y el fork del participante; cada fallo trae su arreglo |
| `kit/prompts/` | los prompts por defecto de las cuatro fases |
| `kit/dashboard/` | el panel local (de demo-factory), con gates y PRs en borrador |
| `sync.sh` | instala o actualiza el kit en un repo de problema |
| `scripts/check-problem-repo.sh` | revisa un repo de problema antes de publicarlo, sin gastar tokens |
| `tests/` | pruebas sin gastar tokens: `claude` y `gh` falsos en `tests/stubs/` |

## Costo y tiempo medidos

Ensayo del 6 de noviembre de 2026 (48 corridas reales, 4 repos, `claude-sonnet-5-5`): **$0.31 por corrida en
promedio, $0.46 como máximo; 2 minutos en promedio, 5 como máximo.** Para el correo de pre-work: unas 4
corridas por participante cuestan alrededor de $1.50.

## Probar el kit

```zsh
python3.12 -m venv venv && venv/bin/pip install -r requirements.txt shellcheck-py
venv/bin/pytest -q
(cd kit && ../venv/bin/shellcheck -x factory.sh doctor.sh lib/telemetry.sh) && venv/bin/shellcheck sync.sh tests/stubs/*
```

CI corre lo mismo en Ubuntu y en macOS (bash 3.2 de serie, sin coreutils, como la laptop de un participante).

## Instalar el kit en un repo de problema

```zsh
./sync.sh ../leaderboard-api      # el repo destino debe estar limpio (git status)
git -C ../leaderboard-api diff    # revisa, y haz commit allí
```

`sync.sh` siempre sobrescribe el motor (`factory.sh`, `doctor.sh`, `lib/`, `dashboard/`), agrega los
prompts que falten, y **nunca** toca lo que es del repo: `gates/`, `AGENTS.md`, `factory.conf` ni un
prompt que ya exista.

## `factory.conf` (uno por repo de problema)

```bash
TEST_CMD="pytest -q"            # obligatorio: el comando de pruebas (los agentes pueden agregarle un archivo)
LINT_CMD="ruff check ."         # opcional: el lint, exacto
SCOPE="app/ tests/"             # obligatorio: lo único que los agentes pueden cambiar
MODEL="claude-sonnet-5-5"       # por defecto; FACTORY_MODEL lo sobrescribe
PATH_PREPEND="venv/bin"         # opcional: rutas que van primero en PATH (venv, node_modules/.bin)
RUNTIME="python3.12"            # opcional: doctor.sh revisa que exista
SETUP="python3 -m venv venv && venv/bin/pip install -r requirements.txt"  # opcional: prepara un clon nuevo; doctor lo sugiere
PROTECT_EXTRA="venv package.json"  # opcional: más rutas que los agentes no pueden editar
MAX_TURNS=40  PHASE_TIMEOUT=300  GATE_TIMEOUT=60   # opcionales
```

## Revisar un repo de problema

```zsh
scripts/check-problem-repo.sh ../workshop-repos/expense-report \
  --trip ../notes/tickets/expense-report/trip.patch diff-size.sh --pass ../notes/tickets/expense-report/pass-2.patch
```

Trabaja sobre un clon nuevo, como lo recibe un participante: el repo está limpio, el kit al día,
`factory.conf` carga, `SETUP` + `TEST_CMD` pasan sin dejar archivos sin ignorar, los gates pasan en
`main`, y cada `--trip` (un parche que simula lo que haría el agente con el ticket trampa) lo detiene
el gate indicado, después de correr los tests y el chequeo de scope como lo hace la fábrica. Con `review`
en vez de un gate, ningún gate debe detenerlo: le toca al revisor. Cada `--pass` (una solución razonable de
un ticket normal) debe pasar todos los gates.

## Ensayar en tu propio repo

GitHub no deja hacer fork de un repo propio. Para ensayar como organizador, en un clon de tu repo:

```zsh
FACTORY_UPSTREAM=sgomezahumada/leaderboard-api FACTORY_NO_PUSH=1 ./factory.sh 1
```

`FACTORY_UPSTREAM` hace que la fábrica use ese repo como upstream en vez de buscar el padre del fork.
Los participantes nunca lo necesitan.
Sin `FACTORY_NO_PUSH=1`, las ramas y los PRs del ensayo van al repo público del taller (y al tablero).

## El contrato de `gates/`

- Cada archivo de `gates/` (menos `README*` y los que empiezan con `.`) corre después de la fase 3 y
  antes de la revisión, en orden por nombre.
- Sale con `0`: pasa. Cualquier otro código: la corrida se detiene, la revisión no corre, y la salida
  del gate (primeras 40 líneas) es el motivo del PR `[REJECTED]`.
- Recibe `FACTORY_BASE` (el commit de `main` del participante donde empezó la corrida),
  `FACTORY_ROOT` (el repo) y `FACTORY_CHANGED` (los archivos que cambiaron los agentes, uno por línea).
- Tiene `GATE_TIMEOUT` segundos (60 por defecto), con un vigilante propio que no necesita coreutils.

## El panel local

```zsh
venv/bin/uvicorn dashboard.server:app --port 8001     # dentro de un repo de problema
```

Abre http://127.0.0.1:8001 y corre `./factory.sh <n>` en una terminal. El panel solo lee `.factory/`.

## Qué pasa si…

- **…el participante usa Linux o WSL.** El motor no usa nada exclusivo de macOS (`sed -i ''`, `shasum`,
  `mapfile`…); una prueba lo vigila y CI corre en Ubuntu.
- **…un gate no es ejecutable o tiene finales de línea de Windows.** El preflight (y `doctor.sh`) lo detecta
  antes de gastar una sola fase, y dice exactamente qué hacer (`chmod +x …` o `perl -pi -e 's/\r$//' …`).
- **…un gate se cuelga.** Se corta a los `GATE_TIMEOUT` segundos y la corrida termina en `[REJECTED]`.
- **…escribió un gate pero no hizo commit.** El preflight dice "Commit your changes first: git add gates
  prompts AGENTS.md && git commit -m …".
- **…el título del ticket tiene comillas, backticks, `$` o `&`.** El título del PR y el marcador JSON lo
  llevan intacto.
- **…corre el mismo ticket dos veces, o su fork quedó atrás.** Cada corrida tiene su propia rama
  (`factory/issue-<n>-<fecha>-<hora>`); `doctor.sh` avisa (sin bloquear) si falta `git pull upstream main`.
- **…una corrida se detiene a mitad (error, límite de turnos, Ctrl+C).** Lo que hizo queda guardado en su
  rama `factory/issue-…` y el participante vuelve a un `main` limpio. Toda corrida, buena o mala, termina en `main`.
- **…el repo no ignora `.factory/` o el panel crea `__pycache__/`.** No importa: `.factory/` se ignora solo y
  `dashboard/` trae su propio `.gitignore`.
- **…tiene un remoto `upstream`.** El motor nombra el fork de forma explícita al preguntarle a `gh`
  por el repo padre; sin eso, `gh` miraría `upstream` y diría que no es un fork.
