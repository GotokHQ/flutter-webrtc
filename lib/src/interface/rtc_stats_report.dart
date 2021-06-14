import 'utils.dart';

class RTCStatsReport {
  RTCStatsReport(
    this.stats, {
    this.timestamp,
  });
  factory RTCStatsReport.fromMap(Map<String, dynamic> map) {
    var statsMap = asStringKeyedMap(map['stats']);
    final stats = statsMap.map(
      (key, value) => MapEntry(
        key,
        StatsReport.fromMap(asStringKeyedMap(value)),
      ),
    );
    return RTCStatsReport(
      stats,
      timestamp: map['timestamp'],
    );
  }

  double? timestamp;
  Map<String, StatsReport> stats;

  @override
  String toString() {
    return '$runtimeType('
        'id: $timestamp, '
        'type: $stats, )';
  }
}

class StatsReport {
  StatsReport(this.id, this.type, this.timestamp, this.values);
  factory StatsReport.fromMap(Map<String, dynamic> map) {
    return StatsReport(map['id'], map['type'], map['timestamp'], map['values']);
  }
  String id;
  String type;
  double timestamp;
  Map<dynamic, dynamic> values;
  @override
  String toString() {
    return '$runtimeType('
        'id: $id, '
        'type: $type, '
        'timestamp: $timestamp, '
        'values: $values )';
  }
}
