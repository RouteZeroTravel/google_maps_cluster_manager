import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_cluster_manager/google_maps_cluster_manager.dart';
import 'package:google_maps_cluster_manager/src/max_dist_clustering.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    hide Cluster;

class GetMarkerResult<T extends ClusterItem> {
  final List<Cluster<T>> clusterableMarkers;
  final List<T> unclusterableMarkers;

  GetMarkerResult({required this.clusterableMarkers, required this.unclusterableMarkers});
}

enum ClusterAlgorithm { GEOHASH, MAX_DIST }

class MaxDistParams {
  final double epsilon;

  MaxDistParams(this.epsilon);
}

class ClusterManager<T extends ClusterItem> {
  ClusterManager(this._items,
      {Future<Marker> Function(Cluster<T>)? clusterBuilder,
      required Future<Marker> Function(T) markerBuilder,
      required void Function() updateClusters,
      this.levels = const [1, 4.25, 6.75, 8.25, 11.5, 14.5, 16.0, 16.5, 20.0],
      this.extraPercent = 0.5,
      this.maxItemsForMaxDistAlgo = 200,
      this.clusterAlgorithm = ClusterAlgorithm.GEOHASH,
      this.maxDistParams,
      this.stopClusteringZoom})
      : this.clusterBuilder = clusterBuilder ?? _basicMarkerBuilder,
      this.markerBuilder = markerBuilder,
      this.updateClusters = updateClusters,
        assert(levels.length <= precision);

  /// Method to build cluster markers
  final Future<Marker> Function(Cluster<T>) clusterBuilder;

  /// Method to build markers
  final Future<Marker> Function(T) markerBuilder;

  /// Method to update the map
  final void Function() updateClusters;

  // Num of Items to switch from MAX_DIST algo to GEOHASH
  final int maxItemsForMaxDistAlgo;

  /// Zoom levels configuration
  final List<double> levels;

  /// Extra percent of markers to be loaded (ex : 0.2 for 20%)
  final double extraPercent;

  // Clusteringalgorithm
  final ClusterAlgorithm clusterAlgorithm;

  final MaxDistParams? maxDistParams;

  /// Zoom level to stop cluster rendering
  final double? stopClusteringZoom;

  /// Precision of the geohash
  static final int precision = kIsWeb ? 12 : 20;

  /// Google Maps map id
  int? _mapId;

  /// List of items
  Iterable<T> get items => _items;
  Iterable<T> _items;

  /// List of items
  Set<Marker> get markers => _markers;
  Set<Marker> _markers = {};

  /// Last known zoom
  late double _zoom;

  final double _maxLng = 180 - pow(10, -10.0) as double;

  /// Set Google Map Id for the cluster manager
  void setMapId(int mapId, {bool withUpdate = true}) async {
    _mapId = mapId;
    _zoom = await GoogleMapsFlutterPlatform.instance.getZoomLevel(mapId: mapId);
    if (withUpdate) updateMap();
  }

  /// Method called on map update to update cluster. Can also be manually called to force update.
  void updateMap() {
    _updateClusters();
  }

  void _updateClusters() async {
    GetMarkerResult<T> result = await getMarkers();
    List<Cluster<T>> mapClusterMarkers = result.clusterableMarkers;
    List<T> mapMarkers = result.unclusterableMarkers;

    final Set<Marker> clusterMarkers =
      Set.from(await Future.wait(mapClusterMarkers.map((m) => clusterBuilder(m))));

    final Set<Marker> listOfMarkers =
      Set.from(await Future.wait(mapMarkers.map((m) => markerBuilder(m))));

    listOfMarkers.addAll(clusterMarkers);

    _markers = listOfMarkers;

    updateClusters();
  }

  /// Update all cluster items
  void setItems(List<T> newItems) {
    _items = newItems;
    updateMap();
  }

  /// Add on cluster item
  void addItem(ClusterItem newItem) {
    _items = List.from([...items, newItem]);
    updateMap();
  }

  /// Method called on camera move
  void onCameraMove(CameraPosition position, {forceUpdate = false}) {
    _zoom = position.zoom;
    if (forceUpdate) {
      updateMap();
    }
  }

  /// Retrieve cluster markers
  Future<GetMarkerResult<T>> getMarkers() async {
    if (_mapId == null) return GetMarkerResult(clusterableMarkers: [], unclusterableMarkers: []);

    final LatLngBounds mapBounds = await GoogleMapsFlutterPlatform.instance
        .getVisibleRegion(mapId: _mapId!);

    late LatLngBounds inflatedBounds;
    if (clusterAlgorithm == ClusterAlgorithm.GEOHASH) {
      inflatedBounds = _inflateBounds(mapBounds);
    } else {
      inflatedBounds = mapBounds;
    }

    List<T> visibleItems = items.where((i) {
      return inflatedBounds.contains(i.location);
    }).toList();

    final unclusterableMarkers = visibleItems.where((i) => !i.canCluster).toList();
    final clusterableMarkers = visibleItems.where((i) => i.canCluster).toList();

    if (stopClusteringZoom != null && _zoom >= stopClusteringZoom!)
      return GetMarkerResult(
        clusterableMarkers: clusterableMarkers.map((i) => Cluster<T>.fromItems([i])).toList(),
        unclusterableMarkers: unclusterableMarkers
      ); 

    List<Cluster<T>> listOfClusteredMarkers;

    if (clusterAlgorithm == ClusterAlgorithm.GEOHASH ||
        visibleItems.length >= maxItemsForMaxDistAlgo) {
      int level = _findLevel(levels);
      listOfClusteredMarkers = _computeClusters(
        clusterableMarkers,
        List.empty(growable: true),
        level: level
      );
    } else {
      listOfClusteredMarkers = _computeClustersWithMaxDist(clusterableMarkers, _zoom);
    }

    final multipleClusters = listOfClusteredMarkers.where(
      (item) => item.isMultiple
      ).toList();
      
    final singleClusters = listOfClusteredMarkers.where(
      (item) => !item.isMultiple
      ).map((cluster) => cluster.items.first).toList();

    singleClusters.addAll(unclusterableMarkers);

    return GetMarkerResult(
      clusterableMarkers: multipleClusters,
      unclusterableMarkers: singleClusters
    );
  }

  LatLngBounds _inflateBounds(LatLngBounds bounds) {
    // Bounds that cross the date line expand compared to their difference with the date line
    double lng = 0;
    if (bounds.northeast.longitude < bounds.southwest.longitude) {
      lng = extraPercent *
          ((180.0 - bounds.southwest.longitude) +
              (bounds.northeast.longitude + 180));
    } else {
      lng = extraPercent *
          (bounds.northeast.longitude - bounds.southwest.longitude);
    }

    // Latitudes expanded beyond +/- 90 are automatically clamped by LatLng
    double lat =
        extraPercent * (bounds.northeast.latitude - bounds.southwest.latitude);

    double eLng = (bounds.northeast.longitude + lng).clamp(-_maxLng, _maxLng);
    double wLng = (bounds.southwest.longitude - lng).clamp(-_maxLng, _maxLng);

    return LatLngBounds(
      southwest: LatLng(bounds.southwest.latitude - lat, wLng),
      northeast:
          LatLng(bounds.northeast.latitude + lat, lng != 0 ? eLng : _maxLng),
    );
  }

  int _findLevel(List<double> levels) {
    for (int i = levels.length - 1; i >= 0; i--) {
      if (levels[i] <= _zoom) {
        return i + 1;
      }
    }

    return 1;
  }

  int _getZoomLevel(double zoom) {
    for (int i = levels.length - 1; i >= 0; i--) {
      if (levels[i] <= zoom) {
        return levels[i].toInt();
      }
    }

    return 1;
  }

  List<Cluster<T>> _computeClustersWithMaxDist(
      List<T> inputItems, double zoom) {
    MaxDistClustering<T> scanner = MaxDistClustering(
      epsilon: maxDistParams?.epsilon ?? 20,
    );

    return scanner.run(inputItems, _getZoomLevel(zoom));
  }

  List<Cluster<T>> _computeClusters(
      List<T> inputItems, List<Cluster<T>> markerItems,
      {int level = 5}) {
    if (inputItems.isEmpty) return markerItems;
    String nextGeohash = inputItems[0].geohash.substring(0, level);
    List<T> items = inputItems
        .where((p) => p.geohash.substring(0, level) == nextGeohash)
        .toList();
    markerItems.add(Cluster<T>.fromItems(items));

    List<T> newInputList = List.from(
        inputItems.where((i) => i.geohash.substring(0, level) != nextGeohash));

    return _computeClusters(newInputList, markerItems, level: level);
  }

  static Future<Marker> Function(Cluster) get _basicMarkerBuilder =>
      (cluster) async {
        return Marker(
          markerId: MarkerId(cluster.getId()),
          position: cluster.location,
          onTap: () {
            print(cluster);
          },
          icon: await _getBasicClusterBitmap(cluster.isMultiple ? 125 : 75,
              text: cluster.isMultiple ? cluster.count.toString() : null),
        );
      };

  static Future<BitmapDescriptor> _getBasicClusterBitmap(int size,
      {String? text}) async {
    final PictureRecorder pictureRecorder = PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint1 = Paint()..color = Colors.red;

    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, paint1);

    if (text != null) {
      TextPainter painter = TextPainter(textDirection: TextDirection.ltr);
      painter.text = TextSpan(
        text: text,
        style: TextStyle(
            fontSize: size / 3,
            color: Colors.white,
            fontWeight: FontWeight.normal),
      );
      painter.layout();
      painter.paint(
        canvas,
        Offset(size / 2 - painter.width / 2, size / 2 - painter.height / 2),
      );
    }

    final img = await pictureRecorder.endRecording().toImage(size, size);
    final data = await img.toByteData(format: ImageByteFormat.png) as ByteData;

    return BitmapDescriptor.fromBytes(data.buffer.asUint8List());
  }
}
