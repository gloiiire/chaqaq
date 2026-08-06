# Runner self-hosted — tests Swift en CI

Les runners GitHub hébergés (`macos-15`) n'ont que Xcode 16.4 / iOS 18.5 SDK,
alors que pinkha cible iOS 26 et utilise `UIGlassEffect` / `.glassEffect()`.
Le job Swift tourne donc sur une machine de dev, qui a le bon Xcode et le
simulateur « Pinkha SIM ».

## Installation

Un runner ne peut servir qu'un seul dépôt : si la machine en héberge déjà un
pour un autre projet, il faut une **seconde instance** dans son propre dossier.

```bash
mkdir -p ~/actions-runner-pinkha && cd ~/actions-runner-pinkha

# Récupérer l'archive (ou réutiliser celle d'un runner existant, même version)
curl -o actions-runner.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-osx-arm64-2.336.0.tar.gz
tar xzf actions-runner.tar.gz

# Le token d'enregistrement est éphémère et scopé au dépôt — ne jamais le logger.
TOKEN=$(gh api -X POST repos/pinkha-app/pinkha/actions/runners/registration-token --jq .token)
./config.sh --unattended \
  --url https://github.com/pinkha-app/pinkha \
  --token "$TOKEN" \
  --name "$(scutil --get ComputerName | tr ' ' '-')-pinkha" \
  --labels self-hosted,macOS,ARM64,xcode27 \
  --work _work

./svc.sh install && ./svc.sh start
```

## Le PATH — le piège qui coûte le premier run

Le service tourne en **LaunchAgent**. launchd n'expose que
`/usr/bin:/bin:/usr/sbin:/sbin` : ni Homebrew, ni cargo, ni les shims rbenv.
Le job échoue alors sur un `command not found` qui ne ressemble à rien de ce
qu'on observe dans un terminal, où tout fonctionne.

Le runner lit un fichier `.env` à sa racine. Créer
`~/actions-runner-pinkha/.env` :

```
PATH=/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/Users/<user>/.cargo/bin:/Users/<user>/.rbenv/shims:/usr/bin:/bin:/usr/sbin:/sbin
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
```

> **La locale n'est pas décorative.** launchd n'expose aucun `LANG`, donc Ruby
> et Python retombent sur US-ASCII et meurent sur le premier octet non-ASCII
> (accents dans les logs de build, emoji dans le nom de machine). C'est ce qui
> a tué xcpretty en cours de run : le tuyau s'est fermé, `xcodebuild` a
> continué d'écrire dedans, et le job est resté pendu 10 minutes jusqu'au
> timeout de collecte de diagnostics du simulateur — avec pour seul indice un
> « Timed out after 600.0 » qui ne désigne pas le coupable.

puis `./svc.sh stop && ./svc.sh start` (le `.env` n'est relu qu'au démarrage).

> **`/opt/homebrew/opt/rustup/bin` est indispensable et contre-intuitif.**
> Rust est installé ici via le rustup de Homebrew, donc les shims `cargo` /
> `rustc` vivent là. `~/.cargo/bin` ne contient que les sous-commandes
> installées par `cargo install` (cargo-audit, cargo-llvm-cov…) — **pas
> `cargo` lui-même**. Mettre uniquement `~/.cargo/bin` donne un `rustup`
> qui répond et un `cargo: command not found` deux lignes plus loin.

Vérifier avant de relancer un run, avec exactement l'environnement du service :

```bash
env -i HOME=$HOME PATH=<le PATH du .env> \
  bash -c 'for t in cargo rustup xcodegen jq xcpretty xcodebuild xcrun; do
    printf "%-11s %s\n" "$t" "$(command -v $t || echo ABSENT)"; done'
```

## Deux autres absences dans un checkout frais

**`app/Config/Secrets.xcconfig`** est gitignored (DSN Sentry, URL du proxy
Notion) : sans lui, `xcodegen` refuse net de générer le projet. La CI copie le
template commité — ses valeurs sont des placeholders, `Observability.start()`
no-op sur un DSN contenant `your-dsn-here`, et Sentry est de toute façon coupé
sous XCTest. Aucun secret réel n'a à exister sur le runner.

**`patch-app-icon.rb`** dépend de la gem Ruby `xcodeproj`, absente de
l'environnement du service. L'étape est donc best-effort : elle réinjecte la
référence à `app/Pinkha.icon` que xcodegen ne conserve pas, ce qui compte pour
un build qu'on expédie mais pas pour des tests.

## Garde anti-fork — non négociable

Le dépôt est **public et les forks sont autorisés**. Sans la condition

```yaml
if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
```

n'importe qui pourrait ouvrir une PR et exécuter du code arbitraire sur une
machine personnelle. Les contributeurs externes restent couverts par le job
Rust ; leur code Swift se teste en poussant la branche dans ce dépôt.

## Runner offline

Le label `xcode27` est custom : quand la machine est éteinte, le job reste en
attente puis expire au `timeout-minutes: 45` au lieu de bloquer la PR
indéfiniment.

## Portée

`PinkhaTests` + `PinkhaIntegrationTests`. Les **XCUITest sont exclus** : ils
exigent une session graphique connectée, alors que le runner tourne en
LaunchAgent. Ils se lancent à la main :

```bash
xcodebuild test -project app/Pinkha.xcodeproj -scheme Pinkha \
  -destination 'id=<UDID>' -only-testing:PinkhaUITests
```

## Les 600 s de collecte de diagnostics — résolu

Chaque run passait exactement 600 s **après** la fin des tests sur
`Failure collecting diagnostics from simulator`. Résolu par un test plan qui
fixe la politique de collecte à `Never` : **~615 s → ~12 s**.

### Ce qui a mené là

Les pistes évidentes sont toutes fausses, et mesurées comme telles :

| Piste | Mesure | Verdict |
| --- | --- | --- |
| Spécifique au runner / session LaunchAgent | 623 s depuis un terminal ordinaire | Réfutée |
| Simulateur pré-démarré | 646 s sur un simulateur neuf jamais démarré | Réfutée |
| Log store du simulateur trop gros | idem | Réfutée |
| Code coverage (piste la plus citée en ligne) | activé nulle part ici | Sans objet |
| `defaults write … CollectTestDiagnosticsOnFailure -bool NO` | 24 s une fois, **614 s** en reproduction | Réfutée |
| Flag `xcodebuild` | `error: invalid option` | Impossible |

La réponse était dans le binaire. `+[IDETestRunSession
shouldCollectDiagnosticsGiven:ideIsInitialized:userDefaultOverrideIsPresent:failureOrErrorPredicate:]`
(IDEFoundation) se réduit à :

```
w19 = boolForKey("CollectTestDiagnosticsOnFailure")   // la VALEUR, pas la présence,
                                                      // malgré le nom du paramètre
w0  = prédicat()                                      // un échec/erreur a-t-il eu lieu ?
w8  = (policy < 3)
if (ideIsInitialized)  w8 = (policy == 2)
if (policy == 0)       w8 = 0        ← le seul court-circuit inconditionnel
if (prédicat == 0)     w8 = 0
if (w19)  return prédicat            // le default court-circuite la politique
          return w8
```

Deux enseignements : le user default ne **désactive** rien — à `YES` il rend la
décision au prédicat d'échec, à `NO` il ne fait rien du tout, ce qui explique
que le poser n'ait servi à rien. Et le seul chemin qui coupe la collecte quoi
qu'il arrive est **`policy == 0`**.

Les valeurs de `XCTHDiagnosticCollectionPolicy` se lisent dans le getter
`description` de XCTHarness, encodées en immédiats de petites chaînes Swift :
**0 = `Never`**, 2 = `Always`.

### Le correctif

`app/Pinkha.xctestplan`, référencé par le scheme via `xcodegen` :

```json
"defaultOptions" : { "diagnosticCollectionPolicy" : "Never" }
```

Mesuré 26 s / 11 s / 12 s sur trois runs consécutifs, contre 623 / 646 / 614 s
avant, avec les mêmes 321 tests. Aucune ligne `Failure collecting diagnostics`
ne subsiste. Vaut pour la CI **et** pour les runs locaux.

Ce qu'on perd : le sysdiagnose / logarchive collecté à l'échec d'un test. Les
échecs d'assertion et leurs messages ne sont pas concernés. Passer la valeur à
`Always` le temps d'un diagnostic si besoin.

> ⚠️ Un correctif a déjà été annoncé ici sur **une seule mesure**, et il était
> faux (le run à 24 s était du bruit). Sur ce symptôme, exiger au moins deux
> mesures concordantes.

## Désinstallation

```bash
cd ~/actions-runner-pinkha
./svc.sh stop && ./svc.sh uninstall
TOKEN=$(gh api -X POST repos/pinkha-app/pinkha/actions/runners/remove-token --jq .token)
./config.sh remove --token "$TOKEN"
```

## Panne : le job tourne, réussit, et reste « queued » pour toujours

Symptôme, vu le 2026-08-06 : le job Swift s'exécute sur le Mac, tous ses
steps passent, les logs remontent (`success rate: 2/2`), le worker écrit
« Raising job completed against run service » puis « Job completed » —
sans une seule erreur. Et GitHub le laisse indéfiniment à :

```
status: queued    runner: aucun
```

La PR reste bloquée sur un check qui n'arrivera jamais.

### Ce que ce n'était pas

Beaucoup de temps perdu sur de fausses pistes. Elles sont listées ici
pour qu'on ne les reprenne pas :

| Piste | Verdict |
| --- | --- |
| Erreurs `SocketException (89)` dans le log du runner | **Bruit normal** — c'est le recyclage du long-poll. Le runner de l'autre dépôt en a 887 et fonctionne. |
| Runner hors ligne, occupé, ou mauvais label | Non — `online`, `busy:false`, `self-hosted,macOS,ARM64,xcode27` conforme. |
| Décalage d'horloge (jetons rejetés) | Non — +0,01 s sur NTP. |
| Version du runner périmée | Non — 2.336.0, la dernière. |
| Garde anti-fork qui exclut le job | Non — PR interne au dépôt. |
| Incident GitHub Actions | Non — composant `operational`. |
| Emoji dans le nom du runner | Plausible, **infirmé** — l'autre runner, au nom ASCII, montrait le même `runner: aucun`. |

### Ce que c'était

Une session de runner corrompue, invisible des deux côtés : le runner
croit avoir rapporté, GitHub n'a jamais enregistré l'acquisition. Aucun
log ne le dit — le seul signal est `runner_name: null` sur un job qu'une
machine est manifestement en train d'exécuter.

**Le symptôme diagnostique** : interroger l'API, pas l'interface.

```bash
RUN=$(gh run list --branch <branche> --limit 1 --json databaseId -q '.[0].databaseId')
gh api repos/pinkha-app/pinkha/actions/runs/$RUN/jobs \
  -q '.jobs[] | "\(.name): \(.status) runner:\(.runner_name // "AUCUN")"'
```

`runner: AUCUN` sur un job en cours d'exécution = session morte.
Vérifier au passage l'historique : si **tous** les runs récents sont dans
cet état, ce n'est pas un incident, c'est une panne installée.

### Remède

Réenregistrer. Rien de moins n'a marché — ni redémarrage du service, ni
`rerun` du job, ni nouveau run.

```bash
cd ~/actions-runner-pinkha
cp .runner /tmp/pinkha-runner-backup.json        # labels + nom, au cas où
./svc.sh stop && ./svc.sh uninstall
./config.sh remove --token "$(gh api -X POST \
  repos/pinkha-app/pinkha/actions/runners/remove-token --jq .token)"

./config.sh --unattended --replace \
  --url https://github.com/pinkha-app/pinkha \
  --token "$(gh api -X POST \
    repos/pinkha-app/pinkha/actions/runners/registration-token --jq .token)" \
  --name macbook-pinkha \
  --labels self-hosted,macOS,ARM64,xcode27 --work _work

./svc.sh install && ./svc.sh start
```

Deux pièges pendant l'opération :

- `config.sh` peut rendre un **401 « Bad credentials »** avec un jeton
  pourtant valide. Refaire l'appel avec un jeton frais a suffi ; ne pas
  conclure à un problème de droits au premier échec.
- `svc.sh install` réécrit le plist mais **ne touche pas `.env`**.
  Vérifier quand même qu'il contient toujours `PATH`, `LANG` et `LC_ALL` :
  sans eux, `cargo`, `xcodegen` et les tests échouent d'une manière qui
  n'a aucun rapport apparent (cf. section PATH plus haut).

Contrôle : le job doit afficher un nom de runner.

```
Swift: in_progress runner:macbook-pinkha
```
