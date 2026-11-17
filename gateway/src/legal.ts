const STYLE = `body{font-family:-apple-system,system-ui,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;line-height:1.5;color:#222}h1{font-size:1.6rem}h2{font-size:1.15rem;margin-top:1.5rem}table{border-collapse:collapse;width:100%;font-size:.95rem}td,th{border:1px solid #ccc;padding:.35rem .5rem;text-align:left;vertical-align:top}`;

// Headers for the two public HTML pages: nothing external, never framed, no referrer leak.
export const LEGAL_PAGE_HEADERS: Record<string, string> = {
  "Content-Type": "text/html; charset=utf-8",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "X-Frame-Options": "DENY",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Cache-Control": "public, max-age=3600",
};

function page(title: string, body: string): string {
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title} – Pécule</title><style>${STYLE}</style></head><body><h1>${title}</h1>${body}<p><small>Dernière mise à jour : 14 septembre 2026.</small></p></body></html>`;
}

// This page describes what the code actually does; keep it in step with links.ts, accounts.ts and the app.
export function privacyPage(contactEmail: string): string {
  return page(
    "Politique de confidentialité",
    `<p>Pécule est une application iPhone personnelle de suivi financier, utilisée exclusivement par son propriétaire, qui opère lui-même la passerelle décrite ici. Cette politique décrit précisément ce que fait la passerelle et l'application avec les données bancaires consultées via Enable Banking, prestataire d'information sur les comptes agréé (DSP2).</p>

<h2>Acteurs</h2>
<table><tr><th>Qui</th><th>Rôle</th></tr>
<tr><td>Le propriétaire</td><td>Seul utilisateur, seul responsable du traitement.</td></tr>
<tr><td>Enable Banking</td><td>Établit la connexion aux banques après consentement explicite du titulaire et transmet soldes et transactions.</td></tr>
<tr><td>Cloudflare</td><td>Sous-traitant technique : héberge la passerelle (Worker) et son stockage clé-valeur (KV) en Europe/monde selon son réseau. Cloudflare peut conserver des métadonnées techniques de requêtes (adresse IP, horodatage) selon sa propre politique ; la passerelle elle-même n'écrit aucun journal applicatif.</td></tr></table>

<h2>Ce que la passerelle conserve (stockage KV)</h2>
<p>Pour chaque liaison bancaire : un identifiant de liaison, son statut, l'identifiant de session Enable Banking, la date de fin de validité du consentement et, pour chaque compte, un identifiant technique, une <strong>empreinte salée de l'IBAN</strong> (SHA-256), l'<strong>IBAN masqué</strong> (seuls les premiers et derniers caractères), le nom du compte, sa devise et son type. Un état d'authentification temporaire est conservé pendant l'autorisation.</p>
<p>La passerelle ne conserve <strong>jamais</strong> l'IBAN complet, les soldes ni les transactions : ces données transitent entre Enable Banking et l'iPhone sans être stockées.</p>

<h2>Durées de conservation côté passerelle</h2>
<table><tr><th>Donnée</th><th>Durée</th></tr>
<tr><td>État d'authentification temporaire</td><td>15 minutes</td></tr>
<tr><td>Liaison en attente d'autorisation</td><td>1 heure</td></tr>
<tr><td>Liaison échouée</td><td>24 heures</td></tr>
<tr><td>Liaison active</td><td>Jusqu'à ce que le compte soit délié dans l'application ; la session Enable Banking est alors révoquée et l'entrée supprimée.</td></tr></table>

<h2>Ce que l'application conserve sur l'iPhone</h2>
<p>Soldes, transactions, catégories et rapprochements sont enregistrés dans la base de données locale de l'application, chiffrée par iOS et incluse dans les sauvegardes de l'iPhone (iCloud ou ordinateur) chiffrées par Apple. Les opérations de plus de 24 mois qui ne sont rattachées à aucune saisie sont purgées automatiquement lors d'une synchronisation complète. Un compte dont le consentement a expiré n'est jamais supprimé automatiquement : ses données restent sur l'iPhone jusqu'à ce que le propriétaire le délie. Les données peuvent être exportées à tout moment (CSV, PDF) depuis les réglages, et sont supprimées avec le compte délié ou avec l'application.</p>

<h2>Informations transmises à la banque</h2>
<p>Lors d'un rafraîchissement déclenché manuellement par le propriétaire, l'adresse IP et l'agent utilisateur de l'appareil sont transmis à la banque via Enable Banking, comme l'exige la DSP2 pour les consultations en présence du titulaire. La passerelle ne les stocke pas.</p>

<h2>Sécurité et risque résiduel</h2>
<p>Toute requête d'accès aux données exige un jeton secret connu seulement de l'application ; les échecs répétés sont limités. Seuls la page d'état technique, ces pages d'information et le retour d'autorisation de la banque sont accessibles sans jeton. Le retour d'autorisation de la banque revient vers l'application par une adresse <code>lifeos://</code> que le système iOS ne réserve pas : une autre application installée sur le même appareil pourrait théoriquement intercepter ce retour, mais elle ne pourrait pas lire la liaison sans le jeton secret. Aucun cookie, aucun outil d'analyse, aucune publicité, aucun tiers.</p>

<h2>Retrait du consentement et droits</h2>
<p>Le consentement peut être révoqué à tout moment en déliant le compte dans l'application ou auprès de la banque. Accès, portabilité (export) et effacement s'exercent directement dans l'application ; pour toute question : <a href="mailto:${contactEmail}">${contactEmail}</a>.</p>`,
  );
}

export function termsPage(contactEmail: string): string {
  return page(
    "Conditions d'utilisation",
    `<p>Pécule est une application personnelle, non commerciale, réservée à l'usage privé de son propriétaire. Elle n'est pas distribuée au public.</p>
<h2>Accès aux comptes bancaires</h2>
<p>L'accès aux informations de compte est réalisé par l'intermédiaire d'Enable Banking, conformément à la directive européenne sur les services de paiement (DSP2), et uniquement après consentement explicite du titulaire, pour la durée autorisée par la banque. Aucune opération de paiement n'est initiée.</p>
<h2>Responsabilités</h2>
<p>L'application est fournie « en l'état », sans garantie. Les informations affichées proviennent des banques et peuvent différer des relevés officiels ; les projections, notes et conseils calculés par l'application ne constituent pas un conseil financier.</p>
<h2>Données</h2>
<p>Le traitement des données est décrit dans la <a href="/privacy">politique de confidentialité</a>. Les données peuvent être exportées depuis les réglages de l'application.</p>
<h2>Droit applicable</h2>
<p>Les présentes conditions sont soumises au droit français.</p>
<h2>Contact</h2>
<p><a href="mailto:${contactEmail}">${contactEmail}</a></p>`,
  );
}
