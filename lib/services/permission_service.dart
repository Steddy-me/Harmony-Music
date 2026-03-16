import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<bool> getExtStoragePermission() async {
    if (GetPlatform.isDesktop) {
      return true;
    }

    if (GetPlatform.isAndroid) {
      // Per evitare dipendenze JNI/Android native lato Windows,
      // usiamo direttamente il ramo più compatibile.
      if (!await Permission.manageExternalStorage.isGranted) {
        final permission = await Permission.manageExternalStorage.request();
        return permission.isGranted;
      }
      return true;
    }

    return true;
  }
}