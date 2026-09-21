import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../ui/chat_session_manager.dart';
import '../ui/whatsapp_chat_screen.dart'; // To get ChatMessageItem

class SqliteDatabaseHelper {
  static const String _databaseName = 'remote_control_chat.db';
  static const int _databaseVersion = 2;

  static const String tableSessions = 'chat_sessions';
  static const String tableMessages = 'chat_messages';

  SqliteDatabaseHelper._privateConstructor();
  static final SqliteDatabaseHelper instance = SqliteDatabaseHelper._privateConstructor();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), _databaseName);
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future _onCreate(Database db, int version) async {
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
    await db.execute('CREATE INDEX idx_msg_session ON $tableMessages (sessionId)');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await db.execute('ALTER TABLE $tableSessions ADD COLUMN vehicleDataJson TEXT;');
        await db.execute('ALTER TABLE $tableSessions ADD COLUMN imagePathsJson TEXT;');
        await db.execute('ALTER TABLE $tableSessions ADD COLUMN expectedImageCount INTEGER;');
        await db.execute('ALTER TABLE $tableSessions ADD COLUMN isReadyToPublish INTEGER;');
      } catch (_) {}
    }
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
      orderBy: 'startTimestamp ASC',
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
    Database db = await instance.database;
    // Also delete associated messages
    await db.delete(tableMessages, where: 'sessionId = ?', whereArgs: [sessionId]);
    return await db.delete(tableSessions, where: 'id = ?', whereArgs: [sessionId]);
  }

  // --- Messages CRUD ---

  Future<int> insertMessage(String sessionId, String deviceId, ChatMessageItem message) async {
    Database db = await instance.database;
    final map = message.toJson();
    map['sessionId'] = sessionId;
    map['deviceId'] = deviceId;
    return await db.insert(
      tableMessages,
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ChatMessageItem>> getMessages(String sessionId) async {
    Database db = await instance.database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableMessages,
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
    );
    return List.generate(maps.length, (i) {
      return ChatMessageItem.fromJson(maps[i]);
    });
  }
  
  Future<int> deleteMessages(String sessionId) async {
    Database db = await instance.database;
    return await db.delete(tableMessages, where: 'sessionId = ?', whereArgs: [sessionId]);
  }
}
