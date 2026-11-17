import os

// Journal de l'app (Console.app, `log show --predicate 'subsystem == "com.nicolas.LifeOS"'`), un Logger par
// catégorie. Règle : ce qui identifie quelqu'un ou une opération (montant, libellé, identifiant de compte ou
// de lien, jeton, URL, texte d'erreur qui peut en contenir) passe en `privacy: .private` ; seul le type de
// l'erreur et un code court restent publics. Un message d'erreur d'API ou de SwiftData peut citer un chemin
// ou un identifiant : on le traite comme privé.
enum AppLog {
    static let subsystem = "com.nicolas.LifeOS"
    static let bank = Logger(subsystem: subsystem, category: "banque")
    static let data = Logger(subsystem: subsystem, category: "donnees")
    static let ui = Logger(subsystem: subsystem, category: "interface")
}
