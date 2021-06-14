Map<String, dynamic> asStringKeyedMap(Map<dynamic, dynamic> map) {
  if (map is Map<String, dynamic>) {
    return map;
  } else {
    return Map<String, dynamic>.from(map);
  }
}
