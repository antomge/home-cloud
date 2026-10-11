# Problèmes rencontrés et leçons apprises

Chaque panne a été une occasion d'apprendre. Format : symptôme → cause → correction → leçon.

### 1. « Failed to spawn container »
- **Cause :** le script avait pris le premier modèle Debian 13 de la liste… en version **arm64**, sur un processeur x86.
- **Correction :** filtrer explicitement `^debian-13-standard_.*_amd64`.
- **Leçon :** ne jamais prendre « le premier résultat » ; vérifier l'architecture.

### 2. Un mauvais numéro de série de disque
- **Cause :** une faute de frappe dans le numéro de série du SSD noté à la main.
- **Correction :** relever le numéro tel que Linux le voit (`lsblk -o NAME,SERIAL`).
- **Leçon :** identifier les disques par numéro de série, mais le copier depuis la machine, jamais à la main. Le script refuse de toucher au disque système.

### 3. Le tableau de bord ne voit pas Jellyfin (erreur 401)
- **Cause :** depuis Jellyfin 10.11, l'ancien en-tête `X-Emby-Token` est refusé par défaut.
- **Correction :** en-tête moderne `Authorization: MediaBrowser Token="…"`.
- **Leçon :** une API évolue ; tester le code de retour plutôt que supposer.

### 4. « Le transcodage ne marche pas »
- **Cause :** le film testé faisait 1,8 Mbit/s, sous la limite de 4 Mbit/s : Jellyfin n'avait aucune raison de transcoder.
- **Correction :** tester avec une limite de 1 Mbit/s ; Quick Sync confirmé, processeur inoccupé à environ 78 %.
- **Leçon :** comprendre la règle de décision avant de conclure à une panne.

### 5. Streamyfin ne fonctionne plus en 5G
- **Cause :** les machines avaient été renommées dans la console Tailscale ; les noms MagicDNS avaient donc changé.
- **Correction :** mettre à jour l'adresse dans l'application.
- **Leçon :** un nom est une dépendance ; le changer casse ce qui s'appuie dessus. D'où l'intérêt, ensuite, de noms stables derrière un proxy.

### 6. Santé du SSD : 39 % ou 61 % ?
- **Cause :** l'attribut SMART 231 du Kingston A400 n'est pas interprété de la même façon selon les outils.
- **Correction :** mesurer le **volume écrit** (attribut 241) rapporté à l'**endurance garantie** (160 To écrits). Seuil « À surveiller » à 50 %.
- **Leçon :** préférer un indicateur objectif et documenté à une valeur « constructeur » ambiguë.

### 7. Un collage de script qui s'emmêle
- **Cause :** la console web de Proxmox (dans le navigateur) mélange les lignes très longues lors d'un collage massif.
- **Correction :** transférer les gros scripts par `scp`, garder des lignes courtes dans ceux qu'on colle.
- **Leçon :** on transfère des fichiers, on ne colle pas 800 lignes dans un terminal.

### 8. Le tableau de bord en 404 derrière le proxy
- **Cause :** `tailscale serve` ne répond qu'aux requêtes adressées à **son propre nom** ; Caddy transmettait le nom demandé par le navigateur.
- **Correction :** `header_up Host <nom MagicDNS complet du serveur>` dans Caddy.
- **Leçon :** en enchaînant deux mandataires, l'en-tête `Host` fait partie du contrat.

### 9. Des adresses IP qui pourraient changer
- **Constat :** le proxy contacte les services par leur IP locale ; une nouvelle adresse distribuée par la box le casserait.
- **Correction :** baux DHCP statiques pour tous les conteneurs, et une plage d'adresses réservée au serveur.
- **Leçon :** un service dont d'autres dépendent doit avoir une adresse stable.
