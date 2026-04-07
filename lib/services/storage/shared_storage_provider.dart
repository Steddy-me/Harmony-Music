abstract class SharedStorageProvider {
  Future<String?> readFile(String name);
  Future<void> writeFile(String name, String content);
  Future<bool> exists(String name);
  Future<DateTime?> lastModified(String name);
}