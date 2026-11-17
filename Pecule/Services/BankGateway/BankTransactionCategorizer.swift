import Foundation

// Assigns one of the app's ExpenseCategory values to a bank transaction from MCC, bank codes and label keywords.
struct BankTransactionCategorizer: Sendable {
    private static let merchantCategoryCodes: [String: ExpenseCategory] = [
        "5411": .groceries, "5422": .groceries, "5441": .groceries, "5451": .groceries, "5462": .groceries, "5499": .groceries,
        "5541": .fuel, "5542": .fuel, "5983": .fuel,
        "4111": .transport, "4112": .transport, "4121": .transport, "4131": .transport, "4784": .transport, "7523": .transport, "7512": .transport, "4789": .transport,
        "5812": .leisure, "5813": .leisure, "5814": .leisure, "5816": .leisure, "7832": .leisure, "7841": .leisure, "7922": .leisure, "7929": .leisure, "7991": .leisure, "7995": .leisure, "7997": .leisure,
        "5912": .health, "8011": .health, "8021": .health, "8031": .health, "8041": .health, "8042": .health, "8043": .health, "8049": .health, "8062": .health, "8071": .health, "8099": .health,
        "6300": .insurance, "5960": .insurance,
        "4814": .subscriptions, "4816": .subscriptions, "4899": .subscriptions, "5968": .subscriptions,
        "8211": .education, "8220": .education, "8241": .education, "8244": .education, "8249": .education, "8299": .education, "5942": .education,
        "4900": .housing, "6513": .housing,
        "5310": .shopping, "5311": .shopping, "5331": .shopping, "5399": .shopping, "5651": .shopping, "5661": .shopping, "5691": .shopping, "5699": .shopping, "5712": .shopping, "5719": .shopping, "5722": .shopping, "5732": .shopping, "5734": .shopping, "5735": .shopping, "5940": .shopping, "5941": .shopping, "5945": .shopping, "5949": .shopping, "5977": .shopping, "5999": .shopping, "5200": .shopping, "5211": .shopping, "5251": .shopping, "5261": .shopping,
    ]

    // Ordered: the first rule whose keyword starts a word in the label wins (so TOTALENERGIES beats TOTAL).
    private static let keywordRules: [(keywords: [String], category: ExpenseCategory)] = [
        (["NETFLIX", "SPOTIFY", "DISNEY", "AMAZON PRIME", "PRIME VIDEO", "APPLE COM BILL", "APPLE COM", "ITUNES", "ICLOUD", "CANAL", "DEEZER", "YOUTUBE", "GOOGLE ONE", "ORANGE", "SFR", "FREE MOBILE", "FREE TELECOM", "FREEBOX", "BOUYGUES", "SOSH", "RED BY SFR", "MICROSOFT", "ADOBE", "CHATGPT", "OPENAI", "CURSOR", "ANTHROPIC", "CLAUDE", "DROPBOX", "NORDVPN", "TWITCH", "PLAYSTATION NETWORK", "XBOX", "NINTENDO SWITCH ONLINE", "BASIC FIT", "FITNESS PARK", "KEEP COOL", "NEONESS", "ON AIR"], .subscriptions),
        (["TOTALENERGIES", "EDF", "ENGIE", "ENEDIS", "GRDF", "VEOLIA", "SUEZ", "SAUR", "LOYER", "AGENCE IMMO", "FONCIA", "NEXITY", "CITYA", "SYNDIC", "TAXE FONCIERE", "TAXE D HABITATION", "EKWATEUR", "OCTOPUS ENERGY", "ILEK", "MINT ENERGIE"], .housing),
        (["TOTAL", "ESSO", "SHELL", "BP ", "AVIA", "STATION SERVICE", "CARBURANT", "AS24", "ELF", "AGIP", "LECLERC STATION", "INTERMARCHE STATION", "CARREFOUR STATION", "SUPER U STATION"], .fuel),
        (["UBER EATS", "DELIVEROO", "JUST EAT", "MCDONALD", "MC DONALD", "MCDO", "BURGER KING", "KFC", "QUICK", "SUBWAY", "DOMINO", "PIZZA", "RESTAURANT", "RESTO", "BRASSERIE", "BISTRO", "KEBAB", "SUSHI", "STARBUCKS", "COLUMBUS CAFE", "CAFE", "DISTRI CAFE", "BAR ", "PUB ", "CINEMA", "UGC", "PATHE", "GAUMONT", "CGR", "STEAM", "PLAYSTATION", "NINTENDO", "EPIC GAMES", "BOWLING", "LASER", "ESCAPE", "THEATRE", "CONCERT", "TICKETMASTER", "FNAC SPECTACLES", "PARC", "ZOO", "MUSEE", "PISCINE", "CROUS", "BOULANGERIE", "PATISSERIE", "CORNER"], .leisure),
        (["CARREFOUR", "LECLERC", "E LECLERC", "LIDL", "AUCHAN", "INTERMARCHE", "MONOPRIX", "MONOP", "FRANPRIX", "CASINO", "GEANT", "PICARD", "BIOCOOP", "SUPER U", "U EXPRESS", "HYPER U", "ALDI", "NATURALIA", "GRAND FRAIS", "MARCHE", "PRIMEUR", "BOUCHERIE", "CORA", "MATCH", "SPAR", "VIVAL", "PROXI", "NETTO", "LEADER PRICE", "COSTCO", "METRO"], .groceries),
        (["SNCF", "OUIGO", "TGV", "TER ", "RATP", "TISSEO", "TCL", "TBM", "RTM", "STAR ", "TRANSDEV", "KEOLIS", "UBER", "BOLT", "HEETCH", "BLABLACAR", "FLIXBUS", "AUTOROUTE", "VINCI", "APRR", "SANEF", "COFIROUTE", "AREA ", "ASF ", "PARKING", "INDIGO", "Q PARK", "EFFIA", "SAEMES", "PEAGE", "AIR FRANCE", "EASYJET", "RYANAIR", "TRANSAVIA", "VUELING", "LIME", "TIER", "DOTT", "VELIB", "GETAROUND", "EUROPCAR", "HERTZ", "AVIS", "SIXT", "CONTROLE TECHNIQUE", "NORAUTO", "FEU VERT", "SPEEDY", "MIDAS"], .transport),
        (["PHARMACIE", "PHARMA", "DOCTOLIB", "DR ", "DOCTEUR", "MEDECIN", "DENTISTE", "ORTHODONT", "OPTICIEN", "OPTIC", "KRYS", "AFFLELOU", "GENERALE D OPTIQUE", "HOPITAL", "CLINIQUE", "LABORATOIRE", "LABO ", "CPAM", "AMELI", "KINE", "OSTEO", "PSY", "VETERINAIRE", "VETO"], .health),
        (["ASSURANCE", "ASSUR", "MAIF", "MACIF", "MATMUT", "MAAF", "AXA", "ALLIANZ", "GMF", "GROUPAMA", "GENERALI", "MUTUELLE", "HARMONIE MUTUELLE", "ALAN", "APRIL", "LUKO", "LEOCARE", "DIRECT ASSURANCE", "EUROFIL", "OLIVIER ASSURANCE"], .insurance),
        (["UNIVERSITE", "UNIV ", "ECOLE", "LYCEE", "COLLEGE", "FAC ", "CAMPUS", "UDEMY", "COURSERA", "OPENCLASSROOMS", "FORMATION", "SCOLAR", "CANTINE", "BIBLIOTHEQUE", "LIBRAIRIE", "GIBERT", "CULTURA"], .education),
        (["AMAZON", "AMZN", "FNAC", "DARTY", "BOULANGER", "CDISCOUNT", "ZARA", "H M ", "H&M", "UNIQLO", "PRIMARK", "KIABI", "CELIO", "JULES", "DECATHLON", "INTERSPORT", "GO SPORT", "NIKE", "ADIDAS", "IKEA", "LEROY MERLIN", "CASTORAMA", "BRICO", "ACTION", "GIFI", "MAISONS DU MONDE", "ALIEXPRESS", "SHEIN", "TEMU", "VINTED", "ZALANDO", "ASOS", "ETAM", "SEPHORA", "NOCIBE", "MARIONNAUD", "YVES ROCHER", "APPLE STORE", "SAMSUNG", "MICROMANIA", "LA POSTE", "COLISSIMO", "MONDIAL RELAY", "CHRONOPOST", "PAYPAL"], .shopping),
    ]

    func category(
        label: String,
        counterparty: String?,
        merchantCategoryCode: String?,
        bankTransactionCode: String?
    ) -> ExpenseCategory {
        if let merchantCategoryCode, let category = Self.merchantCategoryCodes[merchantCategoryCode.trimmingCharacters(in: .whitespaces)] {
            return category
        }
        let text = " " + Self.normalize([label, counterparty ?? ""].joined(separator: " ")) + " "
        for rule in Self.keywordRules {
            for keyword in rule.keywords where text.contains(" " + keyword.trimmingCharacters(in: .whitespaces) + (keyword.hasSuffix(" ") ? " " : "")) {
                return rule.category
            }
        }
        return .other
    }

    static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR")).uppercased()
        let alphanumeric = folded.map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
        return alphanumeric.split(separator: " ").joined(separator: " ")
    }
}
