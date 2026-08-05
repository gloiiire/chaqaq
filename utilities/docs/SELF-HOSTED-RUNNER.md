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

## Connu, non résolu : 600 s de rab par run

Les tests s'exécutent en ~2 s, puis `xcodebuild` reste bloqué exactement 600 s
avant de rendre la main :

```
IDETestOperationsObserverDebug: Failure collecting diagnostics from simulator: Timed out after 600.0
611.167 elapsed -- Testing started completed.
** TEST SUCCEEDED **
```

Le run est vert et les résultats sont fiables. C'est du temps perdu, pas un faux
positif. Bug Xcode 15+ connu : [actions/runner-images
#8693](https://github.com/actions/runner-images/issues/8693) (FB13318262), sans
correctif documenté.

### Ce qui a été mesuré et écarté

Ne pas re-tenter ces pistes, elles sont réfutées par la mesure :

| Piste | Mesure | Verdict |
| --- | --- | --- |
| Spécifique au runner / session LaunchAgent | **623 s** depuis un terminal ordinaire en session graphique | Écarté — rien à voir avec le runner |
| Simulateur pré-démarré par `run-on-sim.sh` | **646 s** sur un simulateur créé de zéro, jamais démarré avant | Écarté |
| Log store du simulateur habituel trop gros | idem, simulateur neuf | Écarté |
| Code coverage activé (piste la plus citée en ligne) | ni le scheme ni un test plan ne l'activent | Sans objet |
| `defaults write com.apple.dt.Xcode CollectTestDiagnosticsOnFailure -bool NO` | 24 s **une fois**, puis **614 s** en reproduisant, clé vérifiée à `false` sur disque | **Écarté** — les 24 s étaient du bruit |
| Passer le réglage en argument `xcodebuild` | `error: invalid option` | Impossible |
| Clé de test plan | absente de la liste d'options de test plan d'`IDEFoundation` | Impossible |

> ⚠️ La leçon la plus utile ici : **une seule mesure ne suffit pas**. Le run à
> 24 s a été pris pour un correctif et a failli entrer dans le repo ; la
> reproduction l'a démenti. Sur ce symptôme précis, exiger deux mesures
> concordantes avant de conclure quoi que ce soit.

### Ce qu'on sait du mécanisme

`IDEFoundation` porte la politique de collecte :

```
CollectTestDiagnosticsOnFailure  /  diagnosticCollectionPolicy
shouldCollectDiagnosticsGiven:ideIsInitialized:userDefaultOverrideIsPresent:…
Determines whether long-running and verbose diagnostics (such as a sysdiagnose
or logarchive) are collected at the end of testing when a failure occurs.
```

Le user default existe donc bien, mais le poser ne supprime pas l'attente —
la collecte semble déclenchée par un autre chemin. Piste non explorée :
désassembler `shouldCollectDiagnosticsGiven:…` pour voir ce qui l'emporte sur
l'override.

## Désinstallation

```bash
cd ~/actions-runner-pinkha
./svc.sh stop && ./svc.sh uninstall
TOKEN=$(gh api -X POST repos/pinkha-app/pinkha/actions/runners/remove-token --jq .token)
./config.sh remove --token "$TOKEN"
```
