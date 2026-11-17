# Lots 1A–1B — Socle d'isolation et authentification serveur

État : implémentation locale du contrôle d'accès, pas une bêta prête à distribuer.

## Séparation des modes

Le déploiement existant reste inchangé. `wrangler.toml` ne lie aucun `IdentityVault` et n'active pas `AUTH_MODE=multi_user`. Le mode historique ne convient qu'à l'usage personnel actuel ; ne jamais donner son bearer aux amis.

Le nouveau mode doit être choisi explicitement. Il utilise des sessions individuelles opaques et vérifie leur propriétaire sur les routes de liaisons, soldes et transactions. Un binding absent donne une erreur, pas un repli vers le bearer historique. Le bearer administrateur n'accède qu'aux diagnostics dans ce mode ; les sessions utilisateur ne donnent pas accès aux diagnostics.

`wrangler.multi-user.local.toml` décrit un environnement local uniquement, avec un stockage Durable Object SQLite. Ne pas le déployer. La configuration des environnements réels nécessitera un accord et une migration coordonnée avec iOS.

## Sessions et stockage

- Jetons aléatoires de 256 bits, seule leur empreinte SHA-256 est persistée.
- Sessions d'une heure par défaut, au maximum 24 heures, révocation immédiate dans le stockage fortement cohérent.
- `UserAccess.issueVerifiedSession` est une fonction serveur interne. Le seul endpoint public qui l'appelle exige une identité Apple vérifiée, jamais le `userId` d'un corps de requête.
- `GET /v1/session` permet de lire l'identité courante ; `DELETE /v1/session` révoque la session utilisée.
- Propriétaire des liaisons dérivé de la session ; les champs propriétaire envoyés par le client sont ignorés.
- Aucun rattachement automatique des anciennes liaisons KV sans propriétaire.
- Les états de callback sont consommés dans une transaction, avec expiration de 15 minutes. Deux callbacks concurrents ne peuvent pas créer deux sessions bancaires.
- Les comptes ne sont accessibles que depuis une liaison du propriétaire, autorisée, non supprimée et dont le consentement n'est pas expiré. Une date de consentement inconnue est refusée.
- Une liaison supprimée ne peut pas être recréée par un callback tardif. Si la banque vient de créer une session, sa révocation est tentée ; un échec de ce nettoyage devra être repris par un mécanisme durable avant diffusion.

Le stockage transactionnel est choisi pour les sessions, la révocation et les états à usage unique. Voir la [documentation Cloudflare du stockage Durable Object](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/).

## Vérifications

Depuis `gateway` : `npm test` puis `npm run typecheck`.

La suite comprend 73 tests Vitest (dont vérification Apple et tests A/B des routes) et cinq tests exécutés dans workerd avec SQLite réel local : callback concurrent, isolation propriétaire, absence de recréation après suppression, révocation de session et consommation atomique des défis de connexion.

`esbuild` et `miniflare` sont épinglés aux versions déjà présentes via Wrangler. Miniflare 5 est actuellement une version alpha dans cette chaîne ; les tests utilisent son adaptateur officiel `convertV4MiniflareOptions`. Toute mise à niveau doit relancer les tests runtime. Aucun test ne contacte une banque ni une ressource de production.

## Authentification Apple implémentée côté serveur

`POST /v1/auth/apple/challenge` crée un défi de cinq minutes. L'application doit transmettre le nonce retourné tel quel à la demande Apple. `POST /v1/auth/apple/session` reçoit le défi et le jeton d'identité Apple. Le serveur vérifie signature RS256 via les clés publiques Apple, émetteur, audience configurée, expiration, date d'émission, sujet et nonce. Les champs d'identité soumis séparément par le client sont ignorés.

Le défi est consommé atomiquement avant vérification : une tentative échouée nécessite un nouveau défi. Les endpoints exigent configuration d'audience et rate limiting ; les corps de connexion sont limités à 16 Kio, indépendamment de Content-Length. Les sessions retournées expirent après une heure. Les jetons Apple ne sont ni conservés ni journalisés. Les clés sont récupérées à l'URL Apple fixe, jamais à une URL contenue dans un jeton.

Références : [vérification Apple](https://developer.apple.com/documentation/signinwithapple/verifying-a-user), [résolution des clés avec jose](https://github.com/panva/jose/blob/main/docs/jwks/remote/functions/createRemoteJWKSet.md).

## Restant avant d'activer le mode pour Nicolas et ses amis

1. Configuration Apple réelle et validation de bout en bout avec iOS ; les tests actuels utilisent des clés synthétiques.
2. Limites supplémentaires par utilisateur sur les créations de sessions/liaisons, au-delà de la limite IP de connexion existante.
3. Intégration iOS : connexion, Keychain, expiration/reconnexion, déconnexion, isolation du stockage et des caches par identité, invalidation des réponses de l'ancien profil.
4. Politique de suppression de profil, révocation des autres sessions et événements de révocation Apple.
5. Migration explicitement vérifiée des liaisons personnelles existantes ; aucune attribution au premier utilisateur connecté.
6. Purge durable des sessions et états expirés, reprises de nettoyage de sessions bancaires orphelines et limites de rétention.
7. Validation de bout en bout, configuration Apple/cloud approuvée et déploiement coordonné. La disponibilité des services et leurs coûts ne sont pas validés par les tests locaux.

Le lot 1 complet reste ouvert tant que ces points ne sont pas traités. Les lots suivants restent décrits dans le plan directeur.
