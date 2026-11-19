PrankCam Pro 1.3.0 (com.chuck.prankcampro) - code source complet
=================================================================

Fichiers
--------
Tweak.xm                  Code source complet du tweak (Logos / Objective-C++), y compris
                          la page HTML/CSS/JS de la telecommande web (chaine kHTML).
Makefile                  Configuration Theos (rootless, arm64, iOS 15.0 minimum).
control                   Informations du paquet .deb (nom, version, dependances).
PrankCamPro.plist         Filtre de chargement : com.apple.UIKit = toutes les apps UIKit.
README.md                 Mode d'emploi detaille.
.github/workflows/build.yml  Compilation automatique sur GitHub Actions (macOS).
telecommande-web/remote.html Copie de la page de la telecommande web, extraite de Tweak.xm
                          pour la lire facilement. Elle n'est PAS utilisee a la compilation :
                          la page reellement servie est celle ecrite dans Tweak.xm.

Il n'y a pas de dossier layout/ ni Resources/ : le projet n'en a pas besoin.

Compiler avec Theos
-------------------
1. Installer Theos (https://theos.dev/docs/installation) et definir THEOS
   (ex. export THEOS=~/theos).
2. Dans ce dossier :
       make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
3. Le .deb est cree dans packages/ :
       packages/com.chuck.prankcampro_1.3.0_iphoneos-arm64.deb

Sur macOS (Xcode installe), la commande ci-dessus suffit.
Sur Linux, avec clang/lld 18 et le SDK iPhoneOS16.5 de theos/sdks, le 1.0.0 a ete compile avec :
       make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1 \
         TARGET=iphone:clang:16.5:15.0 PrankCamPro_USE_MODULES=0 \
         ADDITIONAL_LDFLAGS=-mlinker-version=711
Avec GitHub Actions : chaque push lance la compilation, le .deb est dans les artefacts
("PrankCamPro-deb").

Installation : ouvrir le .deb avec Sileo ou Filza. Il remplace l'ancien com.chuck.prankcam.

Fonctionnalites actuelles (1.0.0)
---------------------------------
- Icone flottante : tap = activer/desactiver (vert ON / contour rouge OFF),
  appui long = telecommande complete, glisser = deplacer (position memorisee).
  Sans video choisie, le tap ouvre le choix de la video puis active.
- Mini-telecommande flottante : bouton 0 = retour au debut et lecture
  (appui long = debut en pause), bouton lecture/pause.
- Telecommande complete : interrupteur ON/OFF, 0, lecture/pause, curseur,
  -5s / -1s / +1s / +5s, choix de video, ajout depuis Photos ou Fichiers,
  masquer les boutons (un petit point les fait revenir).
- Reperes : ajouter le moment actuel avec un nom, tap = saut direct,
  appui long = supprimer. Gardes par video dans cues.json.
- Son video : reglage "Son de la video (sinon mon micro)", allume par defaut.
  Le son n'est jamais joue sur le haut-parleur ; il remplace seulement le micro
  dans les apps qui le recuperent par le meme chemin que la camera.
- Reglages memorises (settings.json) : son, repartir a 0 a l'activation (ON par defaut),
  boucle, mini-telecommande, telecommande web, positions des boutons, derniere video
  (rechargee en pause au debut a l'ouverture de l'app).
- Telecommande web (desactivee par defaut) : http://IP-de-l-iPhone:8765 depuis un autre
  appareil sur le meme Wi-Fi ; ON/OFF, 0, 0 + pause, lecture/pause, -5s/+5s, son, boucle,
  choix de video, reperes.
- Bandeau LIVE PRANK dessine sur chaque image, non desactivable.
- Donnees dans le dossier "PrankCam" (Application Support) de chaque app.


Nouveautes 1.1.0
----------------
- Image a l'endroit : rotation corrigee (constante PC_ROT dans Tweak.xm ; si l'image est
  encore a l'envers sur un appareil, mettre -M_PI_2).
- Qualite : mise a l'echelle Lanczos, contexte Core Image haute qualite, sortie video IOSurface.
  La resolution finale reste celle que l'app hote demande a la camera.
- Telecommande : bouton "Supprimer une vidéo" (confirmation) ; aussi dans la telecommande web.
- Telecommande : bouton "Masquer les réglages" -> petit panneau en bas avec uniquement les
  reperes en carres (2 par ligne) + barre [lecture] [+ Temps] [reglages] [fermer].
  Le choix est memorise.
- Le filigrane LIVE PRANK reste obligatoire sur chaque image (inchange).

Nouveautes 1.2.0 (son)
----------------------
- Le son de la video remplace maintenant aussi le micro dans les apps qui lisent le micro via une
  AudioUnit (appels WhatsApp / Messenger, WebRTC) : hook de AudioUnitRender (entree micro uniquement).
  Avant, seul le chemin AVCaptureAudioDataOutput etait remplace.
- Option "Micro coupé : n'envoyer que le son de la vidéo" (meme reglage "audio", active par defaut) :
  quand la video n'a pas de son ou est en pause, c'est le silence qui est envoye, jamais le micro.
- Qualite : reechantillonnage par interpolation lineaire (au lieu du plus proche voisin) et
  latence audio plafonnee (~0,3 s) pour garder le son cale sur l'image.

Nouveautes 1.3.0
----------------
- Filigrane : bouton pour le placer en bas ou en haut de l'image (reglage "wm_top"). Il reste
  toujours affiche, avec la meme opacite : il ne peut ni etre masque ni rendu plus transparent.
- Qualite image : legere accentuation (CISharpenLuminance) apres la mise a l'echelle, et option
  "Qualite maximale (1080p)" : dans Snapchat / TikTok / WhatsApp / Messenger, un petit preset camera
  est remplace par 1920x1080 quand la camera le permet (relancer l'app apres changement).
  Les apps basees sur WebRTC choisissent parfois leur propre format : le gain y est limite.
