# Substitution des polices du lecteur

## Pourquoi

Les thèmes du lecteur reproduisaient Apple Books en embarquant **Canela Text**
et **Publico Text**, extraites d'un Mac. Ce ne sont pas des polices Apple : ce
sont des fontes de **Commercial Type**, qu'Apple licencie pour Apple Books.

Les avoir sur sa machine autorise à s'en servir ; ça n'autorise pas à les
redistribuer. `pinkha-app/pinkha` est **public**, donc les publier serait une
redistribution de fontes commerciales.

Elles ont été retirées du suivi git avant tout `push`. Vérifié à l'époque :
aucune branche distante ne les contenait, `origin/master`, `origin/staging` et
`origin/dev` non plus — rien n'a jamais été publié, donc rien à révoquer.

## Ce qui les remplace

| Thème | Avant (non redistribuable) | Après (SIL OFL) |
| --- | --- | --- |
| Tranquille | Publico Text — Commercial Type | **Newsreader** — Production Type |
| Calme | Canela Text — Commercial Type | **Playfair Display** — Claus Eggers Sørensen |
| Attention | « Proxima Nova » — jamais embarquée | **Avenir Next** — déjà sur iOS |

Attention n'a jamais eu Proxima Nova : la chaîne de repli rendait déjà Avenir
Next. Le nom affiché dit désormais ce qui s'affiche réellement.

## Comment les substituts ont été choisis

Pas au jugé. Les deux originaux ont été mesurés, puis douze candidats libres
sur la même grille.

**Signature des originaux** (normalisée sur le cadratin) :

| | x/em | cap/em | x/cap | largeur moy. |
| --- | --- | --- | --- | --- |
| Canela Text | 0,506 | 0,732 | 0,691 | 0,522 |
| Publico Text | 0,509 | 0,693 | 0,734 | 0,516 |

Le rapport x/capitale sépare bien les deux : Publico monte plus haut par
rapport à ses capitales, marque des fontes de presse.

**Le critère décisif n'est pas la métrique.** Elle classait Lora en tête pour
Canela, mais rendue à hauteur d'x égale, Lora est trop appuyée et trop
calligraphique — les chiffres ne disent rien de la forme des empattements ni
du contraste. Le test retenu : *le même paragraphe se coupe-t-il aux mêmes
mots ?* Newsreader et Playfair Display passent ce test, les autres non.

### Piège des fontes variables

Les candidats viennent de Google Fonts en fontes variables. Le premier rendu
de la version texte de Playfair paraissait large et pâle : Pillow prenait son
instance **par défaut**, soit `opsz 5 / wdth 112,5 / wght 300` — une instance
qui n'existera jamais dans l'app. Toute comparaison doit figer les axes
(`wght 400`, `opsz 16`) avant de juger. Après quoi Playfair **Display** bat la
version « texte », ce qui est contre-intuitif mais mesurable.

## Ce qui est embarqué

`app/Resources/Fonts/OFL/` — 8 instances statiques (romain, italique, gras,
gras italique) générées avec `fontTools.varLib.instancer`, à `wght 400/700` et
`opsz 16`. 1,2 Mo au total, contre 2,9 Mo pour les `.ttc` retirés.

Les licences accompagnent les fichiers (`OFL-Newsreader.txt`,
`OFL-PlayfairDisplay.txt`), comme la SIL OFL l'exige.

### Noms PostScript

Une instance statique porte un nom PostScript **distinct** de son nom de
famille :

| Famille | PostScript |
| --- | --- |
| `Newsreader` | `NewsreaderRoman-Regular`, `NewsreaderItalic-Italic`, … |
| `Playfair Display` | `PlayfairDisplayRoman-Regular`, … |

`UIFont(name:)` accepte l'un ou l'autre selon les versions d'iOS, d'où la
présence des deux dans les chaînes de candidats de `AppSettings.Theme`. Une
chaîne qui n'aurait que le nom de famille échouerait silencieusement, en
retombant sur une serif système sans rien signaler.

## Si tu veux retrouver le rendu Books exact en local

`app/Resources/Fonts/Bundled/` est gitignoré. Y déposer les `.ttc` d'origine et
remettre leurs noms en tête des chaînes de candidats suffit : le repli est déjà
écrit, rien d'autre à changer. Ça reste un choix personnel, sur ta machine —
ces fichiers ne doivent jamais entrer dans un commit.
