import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/chat_session.dart';
import '../models/chat_message.dart';

class SqliteDatabaseHelper {
  static String get _databaseName {
    String uid;
    try {
      uid = FirebaseAuth.instance.currentUser?.uid ?? 'signed_out';
    } catch (_) {
      uid = 'test';
    }
    return 'remote_control_chat_${sha256.convert(utf8.encode(uid))}.db';
  }

  static const int _databaseVersion = 3;

  static const String tableSessions = 'chat_sessions';
  static const String tableMessages = 'chat_messages';

  SqliteDatabaseHelper._privateConstructor();
  static final SqliteDatabaseHelper instance =
      SqliteDatabaseHelper._privateConstructor();

  static final Map<String, Future<Database>> _databases = {};

  Future<Database> get database {
    final name = _databaseName;
    return _databases.putIfAbsent(name, () => _initDatabase(name));
  }

  Future<Database> _initDatabase(String name) async {
    String path = join(await getDatabasesPath(), name);
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future _onCreate(Database db, int version) async {
    await _createNotificationReceipts(db);
    await db.execute('''
      CREATE TABLE $tableSessions (
        id TEXT PRIMARY KEY,
        deviceId TEXT NOT NULL,
        licensePlate TEXT,
        startTimestamp INTEGER NOT NULL,
        status TEXT NOT NULL,
        lastMessage TEXT,
        vehicleDataJson TEXT,
        imagePathsJson TEXT,
        expectedImageCount INTEGER,
        isReadyToPublish INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE $tableMessages (
        id TEXT PRIMARY KEY,
        sessionId TEXT NOT NULL,
        deviceId TEXT NOT NULL,
        sender TEXT NOT NULL,
        text TEXT,
        mediaType TEXT,
        localFilePath TEXT,
        mediaUrl TEXT,
        caption TEXT,
        timestamp INTEGER NOT NULL,
        audioDurationMs INTEGER
      )
    ''');

    // Index for quick message retrieval by session
    await db.execute(
      'CREATE INDEX idx_msg_session ON $tableMessages (sessionId)',
    );
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 3) await _createNotificationReceipts(db);
    if (oldVersion < 2) {
      try {
        await db.execute(
          'ALTER TABLE $tableSessions ADD COLUMN vehicleDataJson TEXT;',
        );
        await db.execute(
          'ALTER TABLE $tableSessions ADD COLUMN imagePathsJson TEXT;',
        );
        await db.execute(
          'ALTER TABLE $tableSessions ADD COLUMN expectedImageCount INTEGER;',
        );
        await db.execute(
          'ALTER TABLE $tableSessions ADD COLUMN isReadyToPublish INTEGER;',
        );
      } catch (_) {}
    }
  }

  Future<void> _createNotificationReceipts(Database db) => db.execute(
    'CREATE TABLE IF NOT EXISTS notification_receipts (id TEXT PRIMARY KEY, revision INTEGER NOT NULL)',
  );

  /// Shared by the foreground and Android background isolate. A transaction
  /// prevents duplicate/reordered pushes from replacing a newer notification.
  Future<bool> claimNotification(String id, int revision) async {
    final db = await database;
    return db.transaction((tx) async {
      final old = await tx.query(
        'notification_receipts',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (old.isNotEmpty && (old.first['revision'] as int) >= revision)
        return false;
      await tx.insert('notification_receipts', {
        'id': id,
        'revision': revision,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
  }

  // --- Sessions CRUD ---

  Future<int> insertSession(ChatSession session) async {
    Database db = await instance.database;
    return await db.insert(
      tableSessions,
      session.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ChatSession>> getSessions(String deviceId) async {
    Database db = await instance.database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSessions,
      where: 'deviceId = ?',
      whereArgs: [deviceId],
      orderBy: 'startTimestamp DESC',
    );
    return List.generate(maps.length, (i) {
      return ChatSession.fromJson(maps[i]);
    });
  }

  Future<ChatSession?> getSession(String sessionId) async {
    Database db = await instance.database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSessions,
      where: 'id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return ChatSession.fromJson(maps.first);
    }
    return null;
  }

  Future<int> deleteSession(String sessionId) async {
    final db = await database;
    return db.transaction((tx) async {
      await tx.delete(
        tableMessages,
        where: 'sessionId = ?',
        whereArgs: [sessionId],
      );
      return tx.delete(tableSessions, where: 'id = ?', whereArgs: [sessionId]);
    });
  }

  /// The old database had no account owner. Import is explicit and scoped to a
  /// currently owned device; never silently assign it to the next signed-in user.
  Future<int> importLegacyDevice(String deviceId) async {
    final oldPath = join(await getDatabasesPath(), 'remote_control_chat.db');
    if (!await File(oldPath).exists()) return 0;
    final target = await database;
    final legacy = await openDatabase(
      oldPath,
      readOnly: true,
      singleInstance: false,
    );
    try {
      final sessions = await legacy.query(
        tableSessions,
        where: 'deviceId = ?',
        whereArgs: [deviceId],
      );
      var imported = 0;
      for (final row in sessions) {
        final id = row['id'] as String;
        if ((await target.query(
          tableSessions,
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        )).isNotEmpty)
          continue;
        final session = ChatSession.fromJson(row);
        // Never replay old running/waiting jobs: publication may have happened already.
        if (session.status != ChatSessionStatus.draft) {
          session.status = ChatSessionStatus.failed;
          session.lastMessage = 'היסטוריה מיובאת — יש לבדוק באתר אם כבר פורסם';
        }
        final messages = await legacy.query(
          tableMessages,
          where: 'sessionId = ?',
          whereArgs: [id],
        );
        await target.transaction((tx) async {
          await tx.insert(
            tableSessions,
            session.toJson(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          for (final row in messages) {
            await tx.insert(tableMessages, {
              ...row,
              'id': '$id/${row['id']}',
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        });
        imported++;
      }
      return imported;
    } finally {
      await legacy.close();
    }
  }

  // --- Messages CRUD ---

  Future<int> insertMessage(
    String sessionId,
    String deviceId,
    ChatMessageItem message,
  ) async {
    Database db = await instance.database;
    final map = message.toJson();
    map['id'] = '$sessionId/${message.id}';
    map['sessionId'] = sessionId;
    map['deviceId'] = deviceId;
    return await db.insert(
      tableMessages,
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ChatMessageItem>> getMessages(
    String sessionId, {
    int? beforeTimestamp,
  }) async {
    Database db = await instance.database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableMessages,
      where: beforeTimestamp == null
          ? 'sessionId = ?'
          : 'sessionId = ? AND timestamp < ?',
      whereArgs: [sessionId, if (beforeTimestamp != null) beforeTimestamp],
      orderBy: 'timestamp DESC',
      limit: 100,
    );
    return List.generate(maps.length, (i) {
      final row = Map<String, dynamic>.from(maps[maps.length - 1 - i]);
      row['id'] = (row['id'] as String).substring(sessionId.length + 1);
      return ChatMessageItem.fromJson(row);
    });
  }

  Future<int> deleteMessages(String sessionId) async {
    Database db = await instance.database;
    return await db.delete(
      tableMessages,
      where: 'sessionId = ?',
      whereArgs: [sessionId],
    );
  }

  Future<int> deleteMessage(String sessionId, String messageId) async {
    Database db = await instance.database;
    return await db.delete(
      tableMessages,
      where: 'id = ?',
      whereArgs: ['$sessionId/$messageId'],
    );
  }
}
