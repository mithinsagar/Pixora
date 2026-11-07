import SwiftUI
import MapKit
import PixoraCore

/// Photos on a map, from the GPS tags cameras and phones write into them. Pixora's own work stays on this Mac, but
/// the map itself comes from Apple Maps, so it stays off until asked for: no map is requested before that.
struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("placesEnabled") private var enabled = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Places", subtitle: enabled ? "Where your photos were taken" : nil)
                if enabled {
                    Button("Turn Off Map") { enabled = false }.help("Stops loading map images. Your photos and their locations stay as they are.")
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 18).background(Palette.panel)
            Divider().overlay(Palette.rule)
            if enabled { PlacesMap() } else { intro }
        }
        .background(Palette.canvas)
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: "map").font(.system(size: 44, weight: .light)).foregroundStyle(Palette.safelight)
            Text("See your photos on a map").font(Typography.display(26))
            VStack(alignment: .leading, spacing: 10) {
                point("location.fill", "Pins come from the location saved in each photo, read on this Mac.")
                point("network", "The map images come from Apple Maps, so Apple can see which areas you look at. This is the only part of Pixora that uses the internet.")
                point("photo", "Your photos, faces and names are never sent anywhere.")
            }
            .frame(maxWidth: 460)
            Button("Turn On Map") { enabled = true }.buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Palette.ink2).frame(width: 20)
            Text(text).font(.callout).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PlacesMap: View {
    @Environment(AppModel.self) private var model
    @State private var photos: [PlacedPhoto] = []
    @State private var clusters: [PlaceCluster] = []
    @State private var camera: MapCameraPosition = .automatic
    @State private var cell = 5.0
    @State private var unchecked = 0
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if photos.isEmpty {
                EmptyState(symbol: "mappin.slash", title: "No locations yet", message: emptyMessage)
            } else {
                Map(position: $camera) {
                    ForEach(clusters) { c in
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude), anchor: .center) {
                            PlacePin(model: model, cluster: c) { open(c) }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .mapControls { MapZoomStepper(); MapCompass() }
                .onMapCameraChange(frequency: .onEnd) { context in
                    let next = max(context.region.span.longitudeDelta, 0.0002) / 7
                    if abs(next - cell) / cell > 0.15 { cell = next; recluster() }
                }
                .overlay(alignment: .topLeading) { summary.padding(14) }
            }
        }
        .task(id: model.sources.filter(\.isOnline).count) { await load() }
    }

    private var emptyMessage: String {
        if unchecked > 0 {
            return "\(Format.count(unchecked, "photo")) can’t be checked until their card or drive is connected. Pixora reads each photo’s location the next time it’s plugged in."
        }
        return "None of your photos have a saved location. Phones add one automatically; most cameras only do with GPS or a phone link switched on."
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
            Text("\(Format.count(photos.count, "photo"))\(unchecked > 0 ? " · \(unchecked.formatted()) not checked yet" : "")").font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
    }

    private func recluster() {
        let next = Places.cluster(photos, cell: cell)
        withAnimation(Motion.glide) { clusters = next }
    }

    private func load() async {
        let store = model.store
        let roots = Dictionary(uniqueKeysWithValues: model.sources.filter(\.isOnline).map { ($0.id, $0.url) })
        let (all, left) = await Task.detached(priority: .utility) { () -> ([PlacedPhoto], Int) in
            try? Places.backfill(store: store, roots: roots)
            return ((try? store.placedPhotos()) ?? [], (try? store.uncheckedPlaceCount()) ?? 0)
        }.value
        photos = all
        unchecked = left
        loaded = true
        if let box = Self.bounds(of: all) {
            cell = max(box.span.longitudeDelta, 0.002) / 7
            camera = .region(box)
        }
        recluster()
    }

    static func bounds(of photos: [PlacedPhoto]) -> MKCoordinateRegion? {
        guard let minLat = photos.map(\.latitude).min(), let maxLat = photos.map(\.latitude).max(),
              let minLon = photos.map(\.longitude).min(), let maxLon = photos.map(\.longitude).max() else { return nil }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                  span: MKCoordinateSpan(latitudeDelta: min(170, max(0.02, (maxLat - minLat) * 1.5)), longitudeDelta: min(350, max(0.02, (maxLon - minLon) * 1.5))))
    }

    /// A group that can still be split zooms in; photos all from one spot open.
    private func open(_ c: PlaceCluster) {
        if c.photos.count > 1, max(c.latitudeSpan, c.longitudeSpan) > 0.0008, let box = Self.bounds(of: c.photos) {
            withAnimation(.easeInOut(duration: 0.7)) { camera = .region(box) }
        } else {
            model.openViewer(c.photos.map(\.photo), at: c.photos[0].id, title: Format.count(c.photos.count, "photo"))
        }
    }
}

/// Map pins are drawn outside the normal view tree and don't see the environment, so the model is passed in.
private struct PlacePin: View {
    let model: AppModel
    let cluster: PlaceCluster
    let open: () -> Void
    @State private var image: NSImage?
    @State private var shown = false

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .topTrailing) {
                ZStack { Color.gray.opacity(0.4); if let image { Image(nsImage: image).resizable().scaledToFill() } }
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                if cluster.photos.count > 1 {
                    Text(cluster.photos.count.formatted()).font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(Palette.onSafelight)
                        .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
                        .background(Capsule().fill(Palette.safelight)).offset(x: 8, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.12, radius: 12)
        .scaleEffect(shown ? 1 : 0.6).opacity(shown ? 1 : 0)
        .onAppear { withAnimation(Motion.pop) { shown = true } }
        .task(id: cluster.photos[0].id) {
            let p = cluster.photos[0].photo
            image = await ImageCache.shared.photoThumb(p, sourceRoot: model.source(p.sourceID).flatMap { $0.isOnline ? $0.url : nil })
        }
        .accessibilityLabel(Format.count(cluster.photos.count, "photo"))
    }
}
