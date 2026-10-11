# 9. DNS privé et bloqueur de publicités — conteneur 100 « adguard »

Script : `scripts/09-creer-adguard.sh`

## Deux rôles en un

1. **Bloqueur** : AdGuard Home répond « n'existe pas » aux noms des régies publicitaires et des pisteurs. La publicité n'est jamais téléchargée. Résultat mesuré sur un banc d'essai public : **92 %** des éléments bloqués.
2. **DNS privé** : il connaît les noms internes `*.maison.<domaine>`, qui n'existent nulle part ailleurs.

## Brancher tous les appareils, partout

La box Orange ne permet pas de changer le DNS qu'elle distribue. On passe donc par Tailscale : dans la console, AdGuard est déclaré comme **serveur de noms du réseau Tailscale** (avec « Override DNS servers »). Tous les appareils connectés l'utilisent, **à la maison comme en 5G**.

Le serveur et ses conteneurs n'utilisent **pas** AdGuard (`--accept-dns=false`) : un serveur ne doit pas dépendre d'un service qu'il héberge lui-même.

## DNS amont chiffré

AdGuard transmet les autres questions à Quad9 et Cloudflare en **DNS sur HTTPS** : ni la box ni le fournisseur d'accès ne voient les sites consultés.

## Zone DNS privée (split-horizon)

Une réécriture DNS `*.maison.<domaine>` → adresse Tailscale du proxy suffit à faire fonctionner toutes les adresses internes. Sur Internet, ces noms n'existent pas : personne ne peut les découvrir ni les joindre. C'est exactement le rôle d'une **zone Azure Private DNS**.

## Limites

Un bloqueur DNS ne voit que les noms, pas le contenu des pages : il ne peut pas bloquer une publicité servie par le même nom que le site (YouTube, publications sponsorisées). Si le conteneur s'arrête, les appareils Tailscale perdent la résolution de noms : c'est un **point de défaillance unique**, assumé ici et documenté.
