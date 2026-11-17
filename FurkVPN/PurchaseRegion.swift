import Foundation
import StoreKit

/**
 * Where «Купить тариф» and «Продлить» are shown (links to the site's payment page): Russia only. In the App
 * Store's other countries a link to pay outside the App Store breaks its rule 3.1.1 (in-app purchase only).
 * Russia is the phone's region or the country of its App Store account: people in Russia often have an
 * account of another country, made for apps that are gone from the Russian App Store.
 */
enum PurchaseRegion {
    static var phoneInRussia: Bool {
        if #available(iOS 16.0, *) { return Locale.current.region?.identifier == "RU" }
        return Locale.current.regionCode == "RU"
    }

    static func russia() async -> Bool {
        if phoneInRussia { return true }
        return await Storefront.current?.countryCode == "RUS"
    }
}
