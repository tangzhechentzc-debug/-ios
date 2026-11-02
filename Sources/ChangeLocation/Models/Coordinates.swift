import CoreLocation
import Foundation

enum CoordinateSystem: String, CaseIterable, Identifiable {
    case wgs84 = "WGS‑84（GPS / Apple 地图）"
    case gcj02 = "GCJ‑02（高德 / 腾讯坐标）"
    var id: String { rawValue }
}

enum Coordinates {
    // Apple's MapKit API uses WGS‑84 even when the mainland basemap is supplied by Amap.
    // GCJ‑02 conversion is only for explicitly labelled external coordinates.
    static func wgsToGCJ(_ point: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat = point.latitude, lon = point.longitude
        guard lon >= 72.004, lon <= 137.8347, lat >= 0.8293, lat <= 55.8271 else { return point }
        let x = lon - 105, y = lat - 35
        var dLat = -100 + 2*x + 3*y + 0.2*y*y + 0.1*x*y + 0.2*sqrt(abs(x))
        dLat += (20*sin(6*x * .pi) + 20*sin(2*x * .pi))*2/3
        dLat += (20*sin(y * .pi) + 40*sin(y/3 * .pi))*2/3
        dLat += (160*sin(y/12 * .pi) + 320*sin(y * .pi/30))*2/3
        var dLon = 300 + x + 2*y + 0.1*x*x + 0.1*x*y + 0.1*sqrt(abs(x))
        dLon += (20*sin(6*x * .pi) + 20*sin(2*x * .pi))*2/3
        dLon += (20*sin(x * .pi) + 40*sin(x/3 * .pi))*2/3
        dLon += (150*sin(x/12 * .pi) + 300*sin(x/30 * .pi))*2/3
        let rad = lat / 180 * .pi
        let a = 6378245.0, ee = 0.006693421622965943
        let magic = 1 - ee*sin(rad)*sin(rad), root = sqrt(magic)
        dLat = dLat*180 / ((a*(1-ee))/(magic*root) * .pi)
        dLon = dLon*180 / (a/root*cos(rad) * .pi)
        return CLLocationCoordinate2D(latitude: lat+dLat, longitude: lon+dLon)
    }

    static func gcjToWGS(_ point: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        var result = point
        for _ in 0..<10 {
            let projected = wgsToGCJ(result)
            let latError = projected.latitude - point.latitude
            let lonError = projected.longitude - point.longitude
            result.latitude -= latError
            result.longitude -= lonError
            if abs(latError) < 1e-9 && abs(lonError) < 1e-9 { break }
        }
        return result
    }
}
