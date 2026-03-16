import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:widget_marquee/widget_marquee.dart';

import '../../models/playlist.dart';
import '../../services/piped_service.dart';
import '../../services/shared_library_service.dart';
import '/models/media_Item_builder.dart';
import '/ui/widgets/create_playlist_dialog.dart';
import 'common_dialog_widget.dart';
import 'snackbar.dart';

class AddToPlaylist extends StatelessWidget {
  const AddToPlaylist(this.songItems, {super.key});
  final List<MediaItem> songItems;

  @override
  Widget build(BuildContext context) {
    final addToPlaylistController = Get.put(AddToPlaylistController());
    final isPipedLinked = Get.find<PipedServices>().isLoggedIn;

    return CommonDialog(
      child: Container(
        height: isPipedLinked ? 400 : 350,
        padding:
            const EdgeInsets.only(top: 20, bottom: 30, left: 20, right: 20),
        child: Stack(
          children: [
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.only(bottom: 10.0, top: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8.0),
                          child: Marquee(
                            id: "createNewPlaylistx",
                            delay: const Duration(milliseconds: 300),
                            child: Text(
                              "CreateNewPlaylist".tr,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      InkWell(
                        child: const Icon(Icons.playlist_add),
                        onTap: () {
                          Navigator.of(context).pop();
                          showDialog(
                            context: context,
                            builder: (context) => CreateNRenamePlaylistPopup(
                              isCreateNadd: true,
                              songItems: songItems,
                            ),
                          );
                        },
                      )
                    ],
                  ),
                ),
                if (isPipedLinked)
                  Obx(
                    () => Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Radio(
                              value: "piped",
                              groupValue:
                                  addToPlaylistController.playlistType.value,
                              onChanged:
                                  addToPlaylistController.changePlaylistType,
                            ),
                            Text("Piped".tr),
                          ],
                        ),
                        const SizedBox(width: 15),
                        Row(
                          children: [
                            Radio(
                              value: "local",
                              groupValue:
                                  addToPlaylistController.playlistType.value,
                              onChanged:
                                  addToPlaylistController.changePlaylistType,
                            ),
                            Text("local".tr),
                          ],
                        )
                      ],
                    ),
                  ),
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColorLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  height: 250,
                  child: Obx(
                    () => addToPlaylistController.playlists.isNotEmpty
                        ? ListView.builder(
                            itemCount: addToPlaylistController.playlists.length,
                            itemBuilder: (context, index) => ListTile(
                              leading: const Icon(Icons.playlist_play),
                              title: Text(
                                addToPlaylistController.playlists[index].title,
                              ),
                              onTap: () {
                                addToPlaylistController
                                    .addSongsToPlaylist(
                                      songItems,
                                      addToPlaylistController
                                          .playlists[index].playlistId,
                                      context,
                                    )
                                    .then((value) {
                                  if (!context.mounted) return;

                                  if (value) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      snackbar(
                                        context,
                                        "songAddedToPlaylistAlert".tr,
                                        size: SanckBarSize.MEDIUM,
                                      ),
                                    );
                                    Navigator.of(context).pop();
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      snackbar(
                                        context,
                                        "songAlreadyExists".tr,
                                        size: SanckBarSize.MEDIUM,
                                      ),
                                    );
                                    Navigator.of(context).pop();
                                  }
                                });
                              },
                            ),
                          )
                        : Center(
                            child: Text("noLibPlaylist".tr),
                          ),
                  ),
                )
              ],
            ),
            Obx(
              () => (addToPlaylistController.additionInProgress.isTrue &&
                      isPipedLinked)
                  ? const Positioned(
                      top: 60,
                      right: 8,
                      child: SizedBox(
                        height: 15,
                        width: 15,
                        child: CircularProgressIndicator(
                          backgroundColor: Colors.transparent,
                          strokeWidth: 2,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class AddToPlaylistController extends GetxController {
  final RxList<Playlist> playlists = RxList();
  final playlistType = "local".obs;
  final additionInProgress = false.obs;
  List<Playlist> localPlaylists = [];
  List<Playlist> pipedPlaylists = [];

  AddToPlaylistController() {
    _getAllPlaylist();
  }

  Future<void> _getAllPlaylist() async {
    final plstsBox = await Hive.openBox("LibraryPlaylists");

    playlists.value = plstsBox.values
        .map((e) {
          if (e is Map && e["isCloudPlaylist"] == false) {
            return Playlist.fromJson(Map<String, dynamic>.from(e));
          }
          return null;
        })
        .whereType<Playlist>()
        .toList();

    localPlaylists = playlists.toList();

    final res = await Get.find<PipedServices>().getAllPlaylists();
    if (res.code == 1) {
      pipedPlaylists = res.response
          .map<Playlist?>(
            (item) => Playlist(
              title: item['name'],
              playlistId: item['id'],
              description: "Piped Playlist",
              thumbnailUrl: item['thumbnail'],
              isPipedPlaylist: true,
            ),
          )
          .whereType<Playlist>()
          .toList();
    }
  }

  void changePlaylistType(val) {
    playlistType.value = val;
    playlists.value = val == "piped" ? pipedPlaylists : localPlaylists;
  }

  Future<bool> addSongsToPlaylist(
    List<MediaItem> songs,
    String playlistId,
    BuildContext context,
  ) async {
    additionInProgress.value = true;

    try {
      if (playlistType.value == "local") {
        final plstBox = await Hive.openBox(playlistId);
        bool addedAny = false;

        final existingIds = <String>{};

        for (final item in plstBox.values) {
          try {
            if (item is Map) {
              final map = Map<String, dynamic>.from(item);
              final id =
                  map['id']?.toString() ?? map['videoId']?.toString() ?? '';
              if (id.isNotEmpty) {
                existingIds.add(id);
              }
            }
          } catch (e) {
            print('ADD TO PLAYLIST READ EXISTING ERROR => $e');
          }
        }

        for (final element in songs) {
          try {
            print('ADD TO PLAYLIST ELEMENT id => ${element.id}');
            print('ADD TO PLAYLIST ELEMENT title => ${element.title}');
            print('ADD TO PLAYLIST ELEMENT extras => ${element.extras}');

            if (existingIds.contains(element.id)) {
              print('ADD TO PLAYLIST SKIP DUPLICATE => ${element.id}');
              continue;
            }

            Map<String, dynamic> itemJson;

            final downloadsBox = Hive.box("SongDownloads");
            final downloadedRaw = downloadsBox.get(element.id);

            if (downloadedRaw is Map) {
              itemJson = Map<String, dynamic>.from(downloadedRaw);
              print('ADD TO PLAYLIST USING DOWNLOADED ENTRY => ${element.id}');
            } else {
              itemJson = Map<String, dynamic>.from(MediaItemBuilder.toJson(element));
              print('ADD TO PLAYLIST USING MEDIA ITEM ENTRY => ${element.id}');
            }

            final rawExtras = itemJson['extras'];
            final extras = rawExtras is Map
                ? Map<String, dynamic>.from(rawExtras)
                : <String, dynamic>{};

            final sharedPath = extras['sharedPath']?.toString();
            final sharedSongId = extras['sharedSongId']?.toString();
            final isSharedSong = extras['isSharedSong'] == true;

            if (isSharedSong && sharedPath != null && sharedPath.isNotEmpty) {
              extras['url'] = sharedPath;
              extras['sharedSongId'] = sharedSongId;
              extras['sharedPath'] = sharedPath;
              extras['isSharedSong'] = true;

              print('ADD TO PLAYLIST USING EXISTING SHARED => $sharedPath');
            } else {
              final rawUrl = extras['url']?.toString() ?? '';
              final isLocalFile = rawUrl.isNotEmpty &&
                  !rawUrl.startsWith('http://') &&
                  !rawUrl.startsWith('https://');

              if (isLocalFile) {
                final sharedLibrary = Get.find<SharedLibraryService>();
                final sourceFile = File(rawUrl);

                if (await sourceFile.exists()) {
                  final sharedSong =
                      await sharedLibrary.sharedSongsService.importSong(
                    sourceFile,
                  );

                  final newSharedPath =
                      '${sharedLibrary.sharedDir.path}/songs/${sharedSong.filename}';

                  extras['url'] = newSharedPath;
                  extras['sharedSongId'] = sharedSong.id;
                  extras['sharedPath'] = newSharedPath;
                  extras['isSharedSong'] = true;

                  print('ADD TO PLAYLIST SHARED SONG => $newSharedPath');
                } else {
                  print('ADD TO PLAYLIST LOCAL FILE MISSING => $rawUrl');
                }
              } else {
                print('ADD TO PLAYLIST NON-LOCAL URL => $rawUrl');
              }
            }

            itemJson['extras'] = extras;
            await plstBox.add(itemJson);

            existingIds.add(element.id);
            addedAny = true;
          } catch (e) {
            print('ADD TO PLAYLIST ITEM ERROR => $e');
          }
        }

        await plstBox.close();

        try {
          final playlistsBox = await Hive.openBox("LibraryPlaylists");
          final playlistRaw = playlistsBox.get(playlistId);

          if (playlistRaw is Map) {
            final playlist = Playlist.fromJson(Map<String, dynamic>.from(playlistRaw));
            playlist.touch();
            await playlistsBox.put(playlistId, playlist.toJson());
          }
        } catch (e) {
          print('ADD TO PLAYLIST TOUCH PLAYLIST ERROR => $e');
        }

        try {
          await Get.find<SharedLibraryService>().exportPlaylists();
        } catch (e) {
          print('ADD TO PLAYLIST EXPORT ERROR => $e');
        }

        additionInProgress.value = false;
        return addedAny;
      } else {
        final videosId = songs.map((e) => e.id).toList();
        final res =
            await Get.find<PipedServices>().addToPlaylist(playlistId, videosId);
        additionInProgress.value = false;
        return (res.code == 1);
      }
    } catch (e) {
      print('ADD TO PLAYLIST FATAL ERROR => $e');
      additionInProgress.value = false;
      return false;
    }
  }
}