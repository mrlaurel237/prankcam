# PrankCam Pro

Tweak rootless (iOS 15+, Dopamine / palera1n, ElleKit ou Substrate) qui remplace l'image de la caméra par une vidéo, avec un bandeau **LIVE PRANK** toujours visible.

## Utilisation
- **Icône flottante 🎥** (plus de combinaison volume +/-) :
  - tap = activer / désactiver (vert = ON, contour rouge = OFF). S'il n'y a pas encore de vidéo, le choix de la vidéo s'ouvre puis la caméra s'active.
  - appui long = télécommande complète.
  - glisser = déplacer (position mémorisée).
- **Mini-télécommande** `[⏮ 0] [⏯]` :
  - `⏮ 0` = la vidéo revient au début et repart ; appui long = début en pause.
  - `⏯` = lecture / pause.
- **Télécommande complète** : ON/OFF, 0, lecture/pause, curseur, -5s/-1s/+1s/+5s, choix ou ajout de vidéos (Photos / Fichiers), repères nommés, réglages :
  - son de la vidéo (ou ton micro), repartir à 0 à chaque activation (activé par défaut), boucle, mini-télécommande, télécommande web, masquer les boutons (un petit point les fait revenir).
- **Son** (réglages) :
  - *Entendre la vidéo sur mon iPhone* (activé par défaut) + *Volume d'écoute* : le son de la vidéo sort du haut-parleur dès qu'elle joue (bascule automatiquement de l'écouteur vers le haut-parleur, et n'est plus coupé par le bouton silence).
  - *Envoyer le son de la vidéo* (à la place du micro) + *Volume de la vidéo envoyée* (0 à 200 %).
  - *Ajouter ma voix* : envoie la vidéo + ton micro mélangés proprement (de préférence avec des écouteurs).
- **Image** : les couleurs sont maintenant rendues en sRGB / BT.709 (avant, l'image sortait sans gestion des couleurs : trop contrastée et trop saturée ; les vidéos HDR de l'iPhone sont aussi converties correctement). Curseur *Saturation* + bouton *Couleurs d'origine*.
- **Retour image** : *Voir la vidéo sur mon écran* (activé par défaut) : quand la caméra prank est active, tu vois aussi la vidéo dans ton aperçu (petite fenêtre « moi » pendant un appel, appareil photo). Ça n'agit que sur l'affichage, pas sur la caméra.
- **Option avancée** (désactivée par défaut) : *Remplacer aussi les photos et vidéos de l'appareil photo*. Ces hooks ne sont installés que si l'option est activée. Si un appel n'affiche plus que ta photo de profil chez l'autre, coupe-la et relance l'app.
- **Télécommande web** (désactivée par défaut) : depuis un autre téléphone sur le même Wi-Fi, ouvre l'adresse affichée dans les réglages (`http://IP-de-l-iPhone:8765`).

Les vidéos, les repères et les réglages sont gardés dans le dossier `PrankCam` de l'app, donc les vidéos déjà importées avec PrankCam restent disponibles.
Le paquet remplace automatiquement l'ancien `com.chuck.prankcam`.

## Compilation
`make package` avec Theos (voir `.github/workflows/build.yml` : chaque push produit le .deb dans les artefacts GitHub Actions).
