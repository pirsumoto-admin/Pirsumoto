void main() { final map = {'a': false}; try { final m = Map<String, String>.from(map); print(m); } catch (e) { print('Error: $e'); } }
