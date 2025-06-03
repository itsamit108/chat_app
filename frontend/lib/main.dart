// ignore_for_file: camel_case_types, deprecated_member_use
// ignore_for_file: must_be_immutable

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:intl/intl.dart';

// API base URL - update this to your server address
const String apiBaseUrl = 'http://localhost:3000';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UserPreferences.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => OnlineUsersProvider()),
        ChangeNotifierProvider(create: (_) => ChatMessagesProvider()),
        ChangeNotifierProvider(create: (_) => ChatProvider()),
        ChangeNotifierProvider(create: (_) => ChatListProvider()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Chat App',
        theme: ThemeData(
          primarySwatch: Colors.grey,
          scaffoldBackgroundColor: Colors.white,
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            elevation: 0,
            titleTextStyle: TextStyle(
              color: Colors.black,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          cardColor: Colors.white,
          dividerColor: Colors.grey.shade200,
          textTheme: const TextTheme(
            bodyLarge: TextStyle(color: Colors.black87),
            bodyMedium: TextStyle(color: Colors.black87),
          ),
          visualDensity: VisualDensity.adaptivePlatformDensity,
        ),
        home: Builder(
          builder: (context) {
            Future(() {
              SocketService().initSocket(context);
            });
            return const ChatListScreen();
          },
        ),
      ),
    );
  }
}

// User model
class UserModel {
  final String userId;
  final String name;
  final String email;
  final int? lastSeen;

  UserModel({
    required this.userId,
    required this.name,
    required this.email,
    this.lastSeen,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      userId: json['userId'] ?? '',
      name: json['name'] ?? '',
      email: json['email'] ?? '',
      lastSeen: json['lastSeen'],
    );
  }
}

// Chat model for list display
class ChatModel {
  final String chatId;
  final String type;
  final List<ParticipantModel> participants;
  final LastMessageModel? lastMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
  bool isTyping;
  String? typingUserId;

  ChatModel({
    required this.chatId,
    required this.type,
    required this.participants,
    this.lastMessage,
    required this.createdAt,
    required this.updatedAt,
    this.isTyping = false,
    this.typingUserId,
  });

  factory ChatModel.fromJson(Map<String, dynamic> json) {
    return ChatModel(
      chatId: json['chatId'] ?? '',
      type: json['type'] ?? 'private',
      participants: (json['participants'] as List?)
              ?.map((p) => ParticipantModel.fromJson(p))
              .toList() ??
          [],
      lastMessage: json['lastMessage'] != null
          ? LastMessageModel.fromJson(json['lastMessage'])
          : null,
      createdAt:
          DateTime.parse(json['createdAt'] ?? DateTime.now().toIso8601String()),
      updatedAt:
          DateTime.parse(json['updatedAt'] ?? DateTime.now().toIso8601String()),
      isTyping: false,
    );
  }

  // Get other participant (for private chats)
  ParticipantModel? getOtherParticipant(String currentUserId) {
    try {
      return participants.firstWhere(
        (p) => p.participantId != currentUserId,
      );
    } catch (e) {
      return participants.isNotEmpty
          ? participants[0]
          : ParticipantModel(
              participantId: '', participantName: 'Unknown', type: 'member');
    }
  }

  // Get current user's unread count from participant data
  int getCurrentUserUnreadCount(String currentUserId) {
    try {
      final participant = participants.firstWhere(
        (p) => p.participantId == currentUserId,
      );
      return participant.unreadCount;
    } catch (e) {
      return 0;
    }
  }

  // Create copy with updated unread count
  ChatModel copyWithUnreadCount(String userId, int unreadCount) {
    final updatedParticipants = participants.map((p) {
      if (p.participantId == userId) {
        return ParticipantModel(
          participantId: p.participantId,
          participantName: p.participantName,
          type: p.type,
          unreadCount: unreadCount,
        );
      }
      return p;
    }).toList();

    return ChatModel(
      chatId: chatId,
      type: type,
      participants: updatedParticipants,
      lastMessage: lastMessage,
      createdAt: createdAt,
      updatedAt: updatedAt,
      isTyping: isTyping,
      typingUserId: typingUserId,
    );
  }

  // Create copy with new last message
  ChatModel copyWithLastMessage(LastMessageModel newLastMessage) {
    return ChatModel(
      chatId: chatId,
      type: type,
      participants: participants,
      lastMessage: newLastMessage,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      isTyping: isTyping,
      typingUserId: typingUserId,
    );
  }
}

class ParticipantModel {
  final String participantId;
  final String participantName;
  final String type;
  final int unreadCount;

  ParticipantModel({
    required this.participantId,
    required this.participantName,
    required this.type,
    this.unreadCount = 0,
  });

  factory ParticipantModel.fromJson(Map<String, dynamic> json) {
    return ParticipantModel(
      participantId: json['participantId'] ?? '',
      participantName: json['participantName'] ?? '',
      type: json['type'] ?? 'member',
      unreadCount: json['unreadCount'] ?? 0,
    );
  }
}

class LastMessageModel {
  final String content;
  final String messageId;
  final String senderId;
  final String senderName;
  final DateTime timestamp;

  LastMessageModel({
    required this.content,
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
  });

  factory LastMessageModel.fromJson(Map<String, dynamic> json) {
    DateTime timestamp;
    if (json['timestamp'] is int) {
      timestamp = DateTime.fromMillisecondsSinceEpoch(json['timestamp']);
    } else if (json['timestamp'] is String) {
      try {
        timestamp =
            DateTime.fromMillisecondsSinceEpoch(int.parse(json['timestamp']));
      } catch (_) {
        timestamp = DateTime.parse(json['timestamp']);
      }
    } else {
      timestamp = DateTime.now();
    }

    return LastMessageModel(
      content: json['content'] ?? '',
      messageId: json['messageId'] ?? '',
      senderId: json['senderId'] ?? '',
      senderName: json['senderName'] ?? '',
      timestamp: timestamp,
    );
  }
}

class UserPreferences {
  static late SharedPreferences _prefs;

  static Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static String getUserId() {
    return _prefs.getString('userId') ?? '';
  }

  static String getUserName() {
    return _prefs.getString('userName') ?? '';
  }

  static String getUserEmail() {
    return _prefs.getString('userEmail') ?? '';
  }

  static Future<void> setUserData(
      String userId, String name, String email) async {
    await _prefs.setString('userId', userId);
    await _prefs.setString('userName', name);
    await _prefs.setString('userEmail', email);
  }

  static Future<void> clearUserData() async {
    await _prefs.clear();
  }
}

// Provider classes
class OnlineUsersProvider extends ChangeNotifier {
  Set<String> _onlineUsers = {};

  Set<String> get onlineUsers => _onlineUsers;

  void addUser(String userId) {
    _onlineUsers = {..._onlineUsers, userId};
    notifyListeners();
  }

  void removeUser(String userId) {
    final newState = Set<String>.from(_onlineUsers);
    newState.remove(userId);
    _onlineUsers = newState;
    notifyListeners();
  }

  void setUsers(Set<String> users) {
    _onlineUsers = users;
    notifyListeners();
  }

  bool isUserOnline(String userId) {
    return _onlineUsers.contains(userId);
  }
}

class ChatListProvider extends ChangeNotifier {
  List<ChatModel> _chats = [];
  bool _isLoading = false;
  String _searchQuery = '';

  List<ChatModel> get chats => _chats;
  bool get isLoading => _isLoading;
  String get searchQuery => _searchQuery;

  List<ChatModel> get filteredChats {
    if (_searchQuery.isEmpty) return _chats;

    final currentUserId = UserPreferences.getUserId();
    return _chats.where((chat) {
      final otherParticipant = chat.getOtherParticipant(currentUserId);
      return otherParticipant?.participantName
              .toLowerCase()
              .contains(_searchQuery.toLowerCase()) ??
          false;
    }).toList();
  }

  void setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setChats(List<ChatModel> chats) {
    _chats = chats;
    _sortChats();
    notifyListeners();
  }

  void _sortChats() {
    _chats.sort((a, b) {
      final aTime = a.lastMessage?.timestamp ?? a.updatedAt;
      final bTime = b.lastMessage?.timestamp ?? b.updatedAt;
      return bTime.compareTo(aTime);
    });
  }

  void updateChatFromSocket(
    String chatId, {
    LastMessageModel? lastMessage,
    int? unreadCount,
  }) {
    final chatIndex = _chats.indexWhere((chat) => chat.chatId == chatId);
    if (chatIndex == -1) return;

    final currentUserId = UserPreferences.getUserId();
    ChatModel updatedChat = _chats[chatIndex];

    // Update last message if provided
    if (lastMessage != null) {
      updatedChat = updatedChat.copyWithLastMessage(lastMessage);
    }

    // Update unread count if provided
    if (unreadCount != null) {
      updatedChat = updatedChat.copyWithUnreadCount(currentUserId, unreadCount);
    }

    _chats[chatIndex] = updatedChat;
    _sortChats();
    notifyListeners();
  }

  void updateChatTyping(String chatId, String userId, bool isTyping) {
    final chatIndex = _chats.indexWhere((chat) => chat.chatId == chatId);
    if (chatIndex != -1) {
      _chats[chatIndex].isTyping = isTyping;
      _chats[chatIndex].typingUserId = isTyping ? userId : null;
      notifyListeners();
    }
  }

  void resetUnreadCount(String chatId) {
    updateChatFromSocket(chatId, unreadCount: 0);
  }

  int get totalUnreadCount {
    final currentUserId = UserPreferences.getUserId();
    return _chats.fold(
        0, (sum, chat) => sum + chat.getCurrentUserUnreadCount(currentUserId));
  }

  // Force refresh from server
  Future<void> refreshChats() async {
    try {
      final userId = UserPreferences.getUserId();
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/users/$userId/chats'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List<ChatModel> chats = [];

        for (var chatData in data) {
          chats.add(ChatModel.fromJson(chatData));
        }

        setChats(chats);
      }
    } catch (e) {
      print("Error refreshing chats: $e");
    }
  }
}

class ChatProvider extends ChangeNotifier {
  String _chatId = '';
  String _senderId = '';
  Widget _currentPage = Container();

  String get chatId => _chatId;
  String get senderId => _senderId;
  Widget get currentPage => _currentPage;

  void setChatId(String chatId) {
    _chatId = chatId;
    notifyListeners();
  }

  void setSenderId(String senderId) {
    _senderId = senderId;
    notifyListeners();
  }

  void setCurrentPage(Widget page) {
    _currentPage = page;
    notifyListeners();
  }
}

// IMPROVED Message model with better ID handling
class Message {
  final String messageId;
  final String senderId;
  final String messageContent;
  final DateTime timestamp;
  String status;
  final String? tempMessageId; // For tracking temporary messages
  final bool isTemporary; // Flag to identify temporary messages

  Message({
    required this.messageId,
    required this.senderId,
    required this.messageContent,
    required this.timestamp,
    this.status = 'sent',
    this.tempMessageId,
    this.isTemporary = false,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    DateTime timestamp;

    if (json['timestamp'] is int) {
      timestamp = DateTime.fromMillisecondsSinceEpoch(json['timestamp']);
    } else if (json['timestamp'] is String) {
      try {
        timestamp =
            DateTime.fromMillisecondsSinceEpoch(int.parse(json['timestamp']));
      } catch (_) {
        timestamp = DateTime.parse(json['timestamp']);
      }
    } else if (json['createdAt'] != null) {
      timestamp = DateTime.parse(json['createdAt']);
    } else {
      timestamp = DateTime.now();
    }

    return Message(
      messageId:
          json['messageId'] ?? "${DateTime.now().millisecondsSinceEpoch}",
      senderId: json['senderId'] ?? '',
      messageContent: json['content'] ?? json['messageContent'] ?? '',
      timestamp: timestamp,
      status: json['status'] ?? 'sent',
      tempMessageId: json['tempMessageId'],
      isTemporary: json['isTemporary'] ?? false,
    );
  }

  // Create a temporary message with temp ID
  factory Message.temporary({
    required String tempMessageId,
    required String senderId,
    required String messageContent,
    required DateTime timestamp,
  }) {
    return Message(
      messageId: tempMessageId, // Use temp ID as message ID initially
      senderId: senderId,
      messageContent: messageContent,
      timestamp: timestamp,
      status: 'sending',
      tempMessageId: tempMessageId,
      isTemporary: true,
    );
  }

  // Create a copy with updated properties
  Message copyWith({
    String? messageId,
    String? senderId,
    String? messageContent,
    DateTime? timestamp,
    String? status,
    String? tempMessageId,
    bool? isTemporary,
  }) {
    return Message(
      messageId: messageId ?? this.messageId,
      senderId: senderId ?? this.senderId,
      messageContent: messageContent ?? this.messageContent,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      tempMessageId: tempMessageId ?? this.tempMessageId,
      isTemporary: isTemporary ?? this.isTemporary,
    );
  }
}

// IMPROVED ChatMessagesProvider with proper ID tracking
class ChatMessagesProvider extends ChangeNotifier {
  List<Message> _messages = [];
  final Map<String, String> _tempToServerIdMap =
      {}; // Maps temp IDs to server IDs

  List<Message> get messages => _messages;

  void addMessage(Message message) {
    // Check for duplicates using proper ID matching
    final isDuplicate = _messages.any((m) {
      // For temporary messages, check temp ID
      if (message.isTemporary && m.tempMessageId != null) {
        return m.tempMessageId == message.tempMessageId;
      }
      // For server messages, check message ID
      if (!message.isTemporary && !m.isTemporary) {
        return m.messageId == message.messageId;
      }
      // Cross-check: server message matching temp message
      if (!message.isTemporary && m.isTemporary && m.tempMessageId != null) {
        return _tempToServerIdMap[m.tempMessageId!] == message.messageId;
      }
      return false;
    });

    if (!isDuplicate) {
      _messages = [..._messages, message];
      _sortMessages();
      notifyListeners();
    }
  }

  void addMessages(List<Message> messages) {
    if (messages.isEmpty) return;

    final existingIds = _messages.map((m) => m.messageId).toSet();
    final existingTempIds = _messages
        .where((m) => m.tempMessageId != null)
        .map((m) => m.tempMessageId!)
        .toSet();

    final newMessages = messages
        .where((msg) =>
            !existingIds.contains(msg.messageId) &&
            (msg.tempMessageId == null ||
                !existingTempIds.contains(msg.tempMessageId!)))
        .toList();

    if (newMessages.isEmpty) return;

    _messages = [..._messages, ...newMessages];
    _sortMessages();
    notifyListeners();
  }

  void _sortMessages() {
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  void updateMessageStatus(String messageId, String status) {
    bool updated = false;
    final updatedMessages = _messages.map((message) {
      // Update by server message ID
      if (message.messageId == messageId) {
        updated = true;
        return message.copyWith(status: status);
      }
      // Update by temp ID if we have a mapping
      if (message.tempMessageId != null &&
          _tempToServerIdMap[message.tempMessageId!] == messageId) {
        updated = true;
        return message.copyWith(status: status);
      }
      return message;
    }).toList();

    if (updated) {
      _messages = updatedMessages;
      notifyListeners();
    }
  }

  // IMPROVED: Proper temp ID to server ID confirmation
  void confirmMessage({
    required String serverMessageId,
    String? tempMessageId,
    required DateTime serverTimestamp,
    required String status,
  }) {
    bool updated = false;

    final updatedMessages = _messages.map((message) {
      // Find the temporary message to replace
      if (tempMessageId != null &&
          message.tempMessageId == tempMessageId &&
          message.isTemporary) {
        // Map temp ID to server ID
        _tempToServerIdMap[tempMessageId] = serverMessageId;

        updated = true;
        return message.copyWith(
          messageId: serverMessageId,
          timestamp: serverTimestamp,
          status: status,
          isTemporary: false,
        );
      }
      return message;
    }).toList();

    if (updated) {
      _messages = updatedMessages;
      _sortMessages();
      notifyListeners();
    }
  }

  // Handle failed message sending
  void markMessageAsFailed(String tempMessageId) {
    bool updated = false;
    final updatedMessages = _messages.map((message) {
      if (message.tempMessageId == tempMessageId && message.isTemporary) {
        updated = true;
        return message.copyWith(status: 'failed');
      }
      return message;
    }).toList();

    if (updated) {
      _messages = updatedMessages;
      notifyListeners();
    }
  }

  // Retry sending a failed message
  void retryMessage(String tempMessageId) {
    bool updated = false;
    final updatedMessages = _messages.map((message) {
      if (message.tempMessageId == tempMessageId &&
          message.status == 'failed') {
        updated = true;
        return message.copyWith(status: 'sending');
      }
      return message;
    }).toList();

    if (updated) {
      _messages = updatedMessages;
      notifyListeners();
    }
  }

  void clearMessages() {
    _messages = [];
    _tempToServerIdMap.clear();
    notifyListeners();
  }

  // Get pending messages (temporary/failed messages)
  List<Message> get pendingMessages {
    return _messages
        .where((m) =>
            m.isTemporary || m.status == 'failed' || m.status == 'sending')
        .toList();
  }
}


// Socket service with improved message ID handling
class SocketService {
  static final SocketService _instance = SocketService._internal();
  IO.Socket? socket;
  bool isInitialized = false;
  Timer? pingTimer;
  BuildContext? _context;
  String? activeChat;

  factory SocketService() {
    return _instance;
  }

  SocketService._internal();

  void initSocket(BuildContext context) {
    if (isInitialized) return;
    _context = context;

    print("Initializing socket connection");
    final userId = UserPreferences.getUserId();

    if (userId.isEmpty) return;

    socket = IO.io(
        apiBaseUrl,
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .setPath('/socket.io/')
            .disableAutoConnect()
            .setQuery({'userId': userId})
            .build());

    socket!.connect();

    socket?.onConnect((_) {
      print('Socket connected successfully');
      _subscribeToUpdates();
    });

    socket?.onDisconnect((_) {
      print('Socket disconnected');
    });

    socket?.onConnectError((error) {
      print('Socket connection error: $error');
    });

    _setupSocketListeners();

    pingTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (socket?.connected == true) {
        socket?.emit("ping_connection", {'userId': userId});
      } else {
        reconnectSocket();
      }
    });

    isInitialized = true;
  }

  void _subscribeToUpdates() {
    socket
        ?.emit('subscribe_chat_list', {'userId': UserPreferences.getUserId()});
  }

  void _setupSocketListeners() {
    // Set up online status listeners
    socket?.on('online-users', (data) {
      if (data is List) {
        final users = Set<String>.from(data);
        Future(() {
          if (_context != null && mounted()) {
            Provider.of<OnlineUsersProvider>(_context!, listen: false)
                .setUsers(users);
          }
        });
        print('Received online users: ${users.length}');
      }
    });

    socket?.on('user-online', (data) {
      if (data != null && data['userId'] != null) {
        final userId = data['userId'];
        Future(() {
          if (_context != null && mounted()) {
            Provider.of<OnlineUsersProvider>(_context!, listen: false)
                .addUser(userId);
          }
        });
        print('User online: $userId');
      }
    });

    socket?.on('user-offline', (data) {
      if (data != null && data['userId'] != null) {
        final userId = data['userId'];
        Future(() {
          if (_context != null && mounted()) {
            Provider.of<OnlineUsersProvider>(_context!, listen: false)
                .removeUser(userId);
          }
        });
        print('User offline: $userId');
      }
    });

    // Chat list updates
    socket?.on('chat_update', (data) {
      if (data != null && _context != null && mounted()) {
        print('Received chat_update: $data');
        Future(() {
          final chatListProvider =
              Provider.of<ChatListProvider>(_context!, listen: false);

          LastMessageModel? lastMessage;
          if (data['lastMessage'] != null) {
            lastMessage = LastMessageModel.fromJson(data['lastMessage']);
          }

          final unreadCount = data['unreadCount'];

          chatListProvider.updateChatFromSocket(
            data['chatId'],
            lastMessage: lastMessage,
            unreadCount: unreadCount,
          );
        });
      }
    });

    // Chat list typing indicators
    socket?.on('chat_typing', (data) {
      if (data != null && _context != null && mounted()) {
        Future(() {
          final chatListProvider =
              Provider.of<ChatListProvider>(_context!, listen: false);
          chatListProvider.updateChatTyping(
            data['chatId'],
            data['userId'],
            data['isTyping'] ?? false,
          );
        });
      }
    });

    // Message listeners for active chat
    socket?.on('receive_message', (data) {
      if (_context != null && mounted()) {
        Future(() {
          // Update chat messages if we're in the active chat
          if (activeChat == data['chatId']) {
            int timestamp;
            if (data['timestamp'] is int) {
              timestamp = data['timestamp'];
            } else if (data['timestamp'] is String) {
              timestamp = int.tryParse(data['timestamp']) ??
                  DateTime.now().millisecondsSinceEpoch;
            } else {
              timestamp = DateTime.now().millisecondsSinceEpoch;
            }

            final message = Message(
              messageId: data['messageId'],
              senderId: data['senderId'],
              messageContent: data['messageContent'],
              timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
              status: data['status'] ?? 'sent',
              isTemporary: false,
            );

            Provider.of<ChatMessagesProvider>(_context!, listen: false)
                .addMessage(message);

            // Mark message as seen since we're actively viewing this chat
            markMessagesAsSeen(activeChat!);
          }
        });
      }
    });

    socket?.on('message_status_update', (data) {
      if (_context != null &&
          mounted() &&
          data['messageId'] != null &&
          data['status'] != null) {
        Future(() {
          Provider.of<ChatMessagesProvider>(_context!, listen: false)
              .updateMessageStatus(data['messageId'], data['status']);
        });
      }
    });

    socket?.on('user_typing', (data) {
      if (_context != null &&
          mounted() &&
          data['userId'] != null &&
          data['userId'] != UserPreferences.getUserId()) {
        // This is handled in the MessageScreen directly
      }
    });

    // IMPROVED: Better message confirmation with temp ID mapping
    socket?.on('message_confirmation', (data) {
      if (_context != null && mounted() && data['messageId'] != null) {
        Future(() {
          final timestamp = data['timestamp'] is int
              ? data['timestamp']
              : int.tryParse(data['timestamp'].toString()) ??
                  DateTime.now().millisecondsSinceEpoch;

          Provider.of<ChatMessagesProvider>(_context!, listen: false)
              .confirmMessage(
            serverMessageId: data['messageId'],
            tempMessageId: data['tempMessageId'],
            serverTimestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
            status: data['status'] ?? 'sent',
          );
        });
      }
    });

    // IMPROVED: Handle message send failures
    socket?.on('message_failed', (data) {
      if (_context != null && mounted() && data['tempMessageId'] != null) {
        Future(() {
          Provider.of<ChatMessagesProvider>(_context!, listen: false)
              .markMessageAsFailed(data['tempMessageId']);
        });
      }
    });
  }

  bool mounted() {
    return _context != null;
  }

  void reconnectSocket() {
    if (socket?.connected != true) {
      socket?.connect();
    }
  }

  void joinChat(String chatId) {
    if (!isInitialized || socket == null) return;

    final userId = UserPreferences.getUserId();
    socket?.emit('join', {'userId': userId, 'chatId': chatId});
    activeChat = chatId;
    print('Joined chat: $chatId');
  }

  void leaveChat(String chatId) {
    if (socket?.connected == true) {
      final userId = UserPreferences.getUserId();
      socket?.emit('leave', {'userId': userId, 'chatId': chatId});
      if (activeChat == chatId) {
        activeChat = null;
      }
      print('Left chat: $chatId');
    }
  }

  // IMPROVED: Send message with temp ID
  void sendMessage(String chatId, String message, String tempMessageId) {
    if (!isInitialized || socket == null) return;
    final userId = UserPreferences.getUserId();
    socket?.emit('send_message', {
      'senderId': userId,
      'chatId': chatId,
      'message': message,
      'tempMessageId': tempMessageId,
    });
  }

  // Retry sending a failed message
  void retryMessage(String chatId, String message, String tempMessageId) {
    if (_context != null && mounted()) {
      Provider.of<ChatMessagesProvider>(_context!, listen: false)
          .retryMessage(tempMessageId);
      sendMessage(chatId, message, tempMessageId);
    }
  }

  void markMessagesAsSeen(String chatId) {
    if (!isInitialized || socket == null) return;
    final userId = UserPreferences.getUserId();
    socket?.emit('message_seen', {'userId': userId, 'chatId': chatId});

    // Also update local chat list to reset unread count immediately
    if (_context != null && mounted()) {
      Provider.of<ChatListProvider>(_context!, listen: false)
          .resetUnreadCount(chatId);
    }
  }

  void sendTypingStatus(String chatId, bool isTyping) {
    if (!isInitialized || socket == null) return;
    final userId = UserPreferences.getUserId();
    socket?.emit(
        'typing', {'userId': userId, 'chatId': chatId, 'isTyping': isTyping});
  }

  void dispose() {
    pingTimer?.cancel();
    socket?.disconnect();
    socket = null;
    isInitialized = false;
    _context = null;
  }

  bool get isConnected => socket?.connected ?? false;

  bool isUserOnline(String userId) {
    if (_context == null) return false;
    return Provider.of<OnlineUsersProvider>(_context!, listen: false)
        .isUserOnline(userId);
  }

  static void disconnectSocket() {
    if (_instance.isInitialized) {
      _instance.dispose();
    }
  }
}

// Main Chat List Screen
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  List<UserModel> _allUsers = [];

  // Login dialog controllers
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  bool _isLoggingIn = false;
  final _loginFormKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _checkUserLogin();
  }

  void _checkUserLogin() async {
    if (UserPreferences.getUserId().isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showLoginDialog();
      });
    } else {
      _fetchChats();
      _fetchUsers();
    }
  }

  void _showLoginDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.white,
        title: const Text(
          'Welcome to Chat App',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 20,
          ),
        ),
        content: Form(
          key: _loginFormKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Name',
                  labelStyle: TextStyle(color: Colors.grey.shade600),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.black, width: 2),
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailController,
                decoration: InputDecoration(
                  labelText: 'Email',
                  labelStyle: TextStyle(color: Colors.grey.shade600),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.black, width: 2),
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                ),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your email';
                  }
                  if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$')
                      .hasMatch(value)) {
                    return 'Please enter a valid email';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isLoggingIn ? null : _registerUser,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: _isLoggingIn
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ))
                  : const Text('Login',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _registerUser() async {
    if (!_loginFormKey.currentState!.validate()) return;

    setState(() {
      _isLoggingIn = true;
    });

    try {
      final checkResponse = await http.get(
        Uri.parse(
            '$apiBaseUrl/api/users?email=${_emailController.text.trim()}'),
      );

      if (checkResponse.statusCode == 200) {
        final List existingUsers = json.decode(checkResponse.body);

        if (existingUsers.isNotEmpty) {
          final userData = existingUsers.first;
          await UserPreferences.setUserData(
            userData['userId'],
            userData['name'],
            userData['email'],
          );

          if (mounted) {
            Navigator.of(context).pop();
            _fetchChats();
            _fetchUsers();
            SocketService().initSocket(context);
          }
          return;
        }
      }

      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/users'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'name': _nameController.text.trim(),
          'email': _emailController.text.trim(),
        }),
      );

      if (response.statusCode == 201) {
        final userData = json.decode(response.body);
        await UserPreferences.setUserData(
          userData['userId'],
          userData['name'],
          userData['email'],
        );

        if (mounted) {
          Navigator.of(context).pop();
          _fetchChats();
          _fetchUsers();
          SocketService().initSocket(context);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Failed to register: ${response.statusCode}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoggingIn = false;
        });
      }
    }
  }

  String _formatChatTime(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

    if (messageDate == today) {
      return DateFormat('HH:mm').format(dateTime);
    } else if (messageDate == yesterday) {
      return 'Yesterday';
    } else {
      return DateFormat('dd-MM-yyyy').format(dateTime);
    }
  }

  Future<void> _fetchChats({bool showLoading = true}) async {
    final chatListProvider =
        Provider.of<ChatListProvider>(context, listen: false);

    if (showLoading) {
      chatListProvider.setLoading(true);
    }

    try {
      final userId = UserPreferences.getUserId();
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/users/$userId/chats'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List<ChatModel> chats = [];

        for (var chatData in data) {
          chats.add(ChatModel.fromJson(chatData));
        }

        chatListProvider.setChats(chats);
        print('Fetched ${chats.length} chats from server');
      } else {
        print("Error fetching chats: ${response.statusCode}");
      }
    } catch (e) {
      print("Error in chat screen: $e");
    } finally {
      if (showLoading) {
        chatListProvider.setLoading(false);
      }
    }
  }

  Future<void> _fetchUsers() async {
    try {
      final response = await http.get(Uri.parse('$apiBaseUrl/api/users'));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List<UserModel> users = [];

        for (var user in data) {
          if (user['userId'] != UserPreferences.getUserId()) {
            users.add(UserModel.fromJson(user));
          }
        }

        setState(() {
          _allUsers = users;
        });
      }
    } catch (e) {
      print("Error fetching users: $e");
    }
  }

  Future<void> _createChat(UserModel user) async {
    final chatListProvider =
        Provider.of<ChatListProvider>(context, listen: false);
    chatListProvider.setLoading(true);

    try {
      final currentUserId = UserPreferences.getUserId();
      final currentUserName = UserPreferences.getUserName();

      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/chats'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'type': 'private',
          'participants': [
            {
              'participantId': currentUserId,
              'participantName': currentUserName,
              'type': 'member'
            },
            {
              'participantId': user.userId,
              'participantName': user.name,
              'type': 'member'
            }
          ]
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final chatData = json.decode(response.body);

        await _fetchChats(showLoading: false);

        if (mounted) {
          Navigator.of(context)
              .push(
                MaterialPageRoute(
                  builder: (_) => MessageScreen(
                    chatId: chatData['chatId'],
                    senderId: user.userId,
                    name: user.name,
                  ),
                ),
              )
              .then((_) => _fetchChats(showLoading: false));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to create chat'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      chatListProvider.setLoading(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Chats',
          style: TextStyle(
            color: Colors.black,
            fontSize: 28,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.black, size: 24),
            onPressed: () async {
              await UserPreferences.clearUserData();
              SocketService.disconnectSocket();
              _showLoginDialog();
            },
          ),
        ],
      ),
      body: Consumer<ChatListProvider>(
        builder: (context, chatListProvider, child) {
          if (chatListProvider.isLoading) {
            return const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: Colors.black,
                  strokeWidth: 2,
                ),
              ),
            );
          }

          return Column(
            children: [
              // Users horizontal list
              if (_allUsers.isNotEmpty)
                Container(
                  height: 120,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _allUsers.length,
                    itemBuilder: (context, index) {
                      final user = _allUsers[index];
                      final isOnline = Provider.of<OnlineUsersProvider>(context)
                          .isUserOnline(user.userId);

                      return GestureDetector(
                        onTap: () => _createChat(user),
                        child: Container(
                          width: 85,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Stack(
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isOnline
                                            ? Colors.green.shade300
                                            : Colors.grey.shade200,
                                        width: 2,
                                      ),
                                    ),
                                    child: CircleAvatar(
                                      radius: 30,
                                      backgroundColor: Colors.grey.shade100,
                                      child: Text(
                                        user.name.isNotEmpty
                                            ? user.name[0].toUpperCase()
                                            : "?",
                                        style: const TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.black,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (isOnline)
                                    Positioned(
                                      right: 2,
                                      bottom: 2,
                                      child: Container(
                                        width: 16,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: Colors.green,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: Colors.white,
                                            width: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                user.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.black87,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),

              // Search bar
              Container(
                margin: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: TextField(
                  onChanged: (value) {
                    chatListProvider.setSearchQuery(value);
                  },
                  decoration: InputDecoration(
                    hintText: 'Search chats...',
                    hintStyle: TextStyle(color: Colors.grey.shade500),
                    prefixIcon: Icon(Icons.search,
                        color: Colors.grey.shade500, size: 20),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 16, horizontal: 20),
                  ),
                ),
              ),

              // Chat list
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _fetchChats(showLoading: false),
                  color: Colors.black,
                  child: chatListProvider.filteredChats.isEmpty
                      ? const Center(
                          child: Text(
                            "No chats yet. Start a conversation with someone above!",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.grey,
                              fontSize: 16,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: chatListProvider.filteredChats.length,
                          itemBuilder: (context, index) {
                            final chat = chatListProvider.filteredChats[index];
                            final currentUserId = UserPreferences.getUserId();
                            final otherParticipant =
                                chat.getOtherParticipant(currentUserId);

                            if (otherParticipant == null) return Container();

                            final isOnline = Provider.of<OnlineUsersProvider>(
                                    context)
                                .isUserOnline(otherParticipant.participantId);

                            final unreadCount =
                                chat.getCurrentUserUnreadCount(currentUserId);

                            return Container(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.grey.shade100),
                              ),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 12),
                                leading: Stack(
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isOnline
                                              ? Colors.green.shade300
                                              : Colors.grey.shade200,
                                          width: 2,
                                        ),
                                      ),
                                      child: CircleAvatar(
                                        radius: 26,
                                        backgroundColor: Colors.grey.shade100,
                                        child: Text(
                                          otherParticipant
                                                  .participantName.isNotEmpty
                                              ? otherParticipant
                                                  .participantName[0]
                                                  .toUpperCase()
                                              : "?",
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.black,
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (isOnline)
                                      Positioned(
                                        right: 0,
                                        bottom: 0,
                                        child: Container(
                                          width: 14,
                                          height: 14,
                                          decoration: BoxDecoration(
                                            color: Colors.green,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                title: Text(
                                  otherParticipant.participantName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 17,
                                    color: Colors.black,
                                  ),
                                ),
                                subtitle: chat.isTyping
                                    ? Text(
                                        "Typing...",
                                        style: TextStyle(
                                          color: Colors.blue.shade600,
                                          fontStyle: FontStyle.italic,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      )
                                    : Text(
                                        chat.lastMessage?.content.isEmpty ??
                                                true
                                            ? "No messages yet"
                                            : chat.lastMessage!.content,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: unreadCount > 0
                                              ? Colors.black87
                                              : Colors.grey.shade600,
                                          fontWeight: unreadCount > 0
                                              ? FontWeight.w500
                                              : FontWeight.normal,
                                          fontSize: 14,
                                        ),
                                      ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (chat.lastMessage != null)
                                      Text(
                                        _formatChatTime(
                                            chat.lastMessage!.timestamp),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: unreadCount > 0
                                              ? Colors.black87
                                              : Colors.grey.shade500,
                                          fontWeight: unreadCount > 0
                                              ? FontWeight.w500
                                              : FontWeight.normal,
                                        ),
                                      ),
                                    if (unreadCount > 0)
                                      Container(
                                        margin: const EdgeInsets.only(top: 6),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.red,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        constraints: const BoxConstraints(
                                          minWidth: 24,
                                          minHeight: 24,
                                        ),
                                        child: Text(
                                          unreadCount > 99
                                              ? '99+'
                                              : unreadCount.toString(),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => MessageScreen(
                                        chatId: chat.chatId,
                                        senderId:
                                            otherParticipant.participantId,
                                        name: otherParticipant.participantName,
                                      ),
                                    ),
                                  ).then(
                                      (_) => _fetchChats(showLoading: false));
                                },
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class MessageScreen extends StatefulWidget {
  final String chatId, senderId, name;

  const MessageScreen({
    super.key,
    required this.chatId,
    required this.senderId,
    required this.name,
  });

  @override
  State<MessageScreen> createState() => _MessageScreenState();
}

class _MessageScreenState extends State<MessageScreen> {
  late String currentUserId;
  final messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Map<String, bool> typingUsers = {};
  Timer? typingTimer;
  bool isTyping = false;

  bool _isLoadingMore = false;
  bool _hasMoreMessages = true;
  final int _messagesPerPage = 50;
  bool _isFirstLoad = true;
  String? _beforeTimestamp;

  final socketService = SocketService();

  @override
  void initState() {
    super.initState();
    currentUserId = UserPreferences.getUserId();

    if (!socketService.isInitialized) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        socketService.initSocket(context);
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      setupSocketListeners();
      socketService.joinChat(widget.chatId);
      socketService.markMessagesAsSeen(widget.chatId);
    });

    _scrollController.addListener(_scrollListener);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<ChatMessagesProvider>(context, listen: false).clearMessages();
      getMessages();
    });
  }

  String _formatDateForHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(date.year, date.month, date.day);

    if (messageDate == today) {
      return "Today";
    } else if (messageDate == yesterday) {
      return "Yesterday";
    } else if (now.difference(messageDate).inDays < 7) {
      return DateFormat('EEEE').format(date);
    } else {
      return DateFormat('MMMM d, y').format(date);
    }
  }

  void _scrollListener() {
    if (_scrollController.position.pixels <=
            _scrollController.position.minScrollExtent + 50 &&
        !_isLoadingMore &&
        _hasMoreMessages) {
      _loadMoreMessages();
    }
  }

  void setupSocketListeners() {
    final socket = socketService.socket;
    if (socket == null) return;

    socket.off('receive_message');
    socket.off('message_status_update');
    socket.off('user_typing');
    socket.off('message_confirmation');
    socket.off('message_failed');

    socket.on('receive_message', (data) {
      if (mounted) {
        int timestamp;
        if (data['timestamp'] is int) {
          timestamp = data['timestamp'];
        } else if (data['timestamp'] is String) {
          timestamp = int.tryParse(data['timestamp']) ??
              DateTime.now().millisecondsSinceEpoch;
        } else {
          timestamp = DateTime.now().millisecondsSinceEpoch;
        }

        final message = Message(
          messageId: data['messageId'],
          senderId: data['senderId'],
          messageContent: data['messageContent'],
          timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
          status: data['status'] ?? 'sent',
          isTemporary: false,
        );

        Provider.of<ChatMessagesProvider>(context, listen: false)
            .addMessage(message);

        socketService.markMessagesAsSeen(widget.chatId);
        _scrollToBottom();
      }
    });

    socket.on('message_status_update', (data) {
      if (mounted && data['messageId'] != null && data['status'] != null) {
        Provider.of<ChatMessagesProvider>(context, listen: false)
            .updateMessageStatus(data['messageId'], data['status']);
      }
    });

    socket.on('user_typing', (data) {
      if (mounted &&
          data['userId'] != null &&
          data['userId'] != currentUserId) {
        setState(() {
          typingUsers[data['userId']] = data['isTyping'];
        });
      }
    });

    socket.on('message_confirmation', (data) {
      if (mounted && data['messageId'] != null) {
        final timestamp = data['timestamp'] is int
            ? data['timestamp']
            : int.tryParse(data['timestamp'].toString()) ??
                DateTime.now().millisecondsSinceEpoch;

        Provider.of<ChatMessagesProvider>(context, listen: false)
            .confirmMessage(
          serverMessageId: data['messageId'],
          tempMessageId: data['tempMessageId'],
          serverTimestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
          status: data['status'] ?? 'sent',
        );
      }
    });

    socket.on('message_failed', (data) {
      if (mounted && data['tempMessageId'] != null) {
        Provider.of<ChatMessagesProvider>(context, listen: false)
            .markMessageAsFailed(data['tempMessageId']);
      }
    });
  }

  void handleTyping(bool typing) {
    if (isTyping != typing) {
      isTyping = typing;
      socketService.sendTypingStatus(widget.chatId, typing);
    }

    typingTimer?.cancel();
    if (typing) {
      typingTimer = Timer(const Duration(seconds: 3), () {
        handleTyping(false);
      });
    }
  }

  void getMessages() async {
    setState(() {
      _isLoadingMore = true;
    });

    var url =
        '$apiBaseUrl/api/chats/${widget.chatId}/messages?limit=$_messagesPerPage';
    if (_beforeTimestamp != null) {
      url += '&before=$_beforeTimestamp';
    }

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final List data = json.decode(response.body);

        _hasMoreMessages = data.length >= _messagesPerPage;

        if (data.isNotEmpty) {
          _beforeTimestamp = data.first["createdAt"];
        }

        List<Message> parsedMessages = [];
        for (var msg in data) {
          try {
            parsedMessages.add(Message.fromJson(msg));
          } catch (e) {
            print("Error parsing message: $e");
          }
        }

        Provider.of<ChatMessagesProvider>(context, listen: false)
            .addMessages(parsedMessages);

        if (_isFirstLoad) {
          _scrollToBottom(animated: false);
          _isFirstLoad = false;
        }

        socketService.markMessagesAsSeen(widget.chatId);
      } else {
        print("Error fetching messages: ${response.statusCode}");
      }
    } catch (e) {
      print("Error fetching messages: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  void _loadMoreMessages() {
    if (_hasMoreMessages && !_isLoadingMore) {
      getMessages();
    }
  }

  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final position = _scrollController.position.maxScrollExtent;
        if (animated) {
          _scrollController.animateTo(
            position,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        } else {
          _scrollController.jumpTo(position);
        }
      }
    });
  }

  // IMPROVED: Send message with temp ID tracking
  void sendMessage() {
    if (messageController.text.isEmpty) return;

    final messageText = messageController.text.trim();
    final tempMessageId =
        "${DateTime.now().millisecondsSinceEpoch}_$currentUserId";

    // Create temporary message
    final tempMessage = Message.temporary(
      tempMessageId: tempMessageId,
      senderId: currentUserId,
      messageContent: messageText,
      timestamp: DateTime.now(),
    );

    // Add to UI immediately
    Provider.of<ChatMessagesProvider>(context, listen: false)
        .addMessage(tempMessage);

    // Send to server with temp ID
    socketService.sendMessage(widget.chatId, messageText, tempMessageId);

    messageController.clear();
    handleTyping(false);
    _scrollToBottom();
  }

  @override
  void dispose() {
    if (isTyping) {
      socketService.sendTypingStatus(widget.chatId, false);
    }

    socketService.leaveChat(widget.chatId);
    typingTimer?.cancel();
    _scrollController.removeListener(_scrollListener);
    messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOnline =
        Provider.of<OnlineUsersProvider>(context).isUserOnline(widget.senderId);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          children: [
            Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isOnline
                          ? Colors.green.shade300
                          : Colors.grey.shade200,
                      width: 2,
                    ),
                  ),
                  child: CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.grey.shade100,
                    child: Text(
                      widget.name.isNotEmpty
                          ? widget.name[0].toUpperCase()
                          : "?",
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
                if (isOnline)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  if (isOnline)
                    Text(
                      "Online",
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.green.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Consumer<ChatMessagesProvider>(
                builder: (context, messagesProvider, child) {
                  final messages = messagesProvider.messages;

                  return ListView.builder(
                    controller: _scrollController,
                    itemCount: messages.length +
                        (_isLoadingMore ? 1 : 0) +
                        (!_hasMoreMessages && messages.isNotEmpty ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (_isLoadingMore && index == 0) {
                        return Container(
                          height: 40,
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                        );
                      }

                      if (!_hasMoreMessages && !_isLoadingMore && index == 0) {
                        return Container(
                          padding: const EdgeInsets.symmetric(vertical: 12.0),
                          child: Center(
                            child: Text(
                              "No more messages",
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ),
                        );
                      }

                      final messageIndex = index -
                          (_isLoadingMore ? 1 : 0) -
                          (!_hasMoreMessages && !_isLoadingMore ? 1 : 0);

                      if (messageIndex < 0 || messageIndex >= messages.length) {
                        return const SizedBox.shrink();
                      }

                      final message = messages[messageIndex];
                      final isCurrentUser = message.senderId == currentUserId;

                      bool showDateHeader = false;
                      if (messageIndex == 0) {
                        showDateHeader = true;
                      } else if (messageIndex > 0) {
                        final previousMessage = messages[messageIndex - 1];
                        final previousDay = DateTime(
                          previousMessage.timestamp.year,
                          previousMessage.timestamp.month,
                          previousMessage.timestamp.day,
                        );
                        final currentDay = DateTime(
                          message.timestamp.year,
                          message.timestamp.month,
                          message.timestamp.day,
                        );
                        showDateHeader = previousDay != currentDay;
                      }

                      return Column(
                        children: [
                          if (showDateHeader)
                            Container(
                              margin:
                                  const EdgeInsets.symmetric(vertical: 12.0),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    _formatDateForHeader(message.timestamp),
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          MessageWidget(
                            message: message,
                            isCurrentUser: isCurrentUser,
                            showAvatar: !isCurrentUser,
                            otherUserName: widget.name,
                            onRetry: (tempMessageId) {
                              // Retry failed message
                              final failedMessage = messages.firstWhere(
                                (m) => m.tempMessageId == tempMessageId,
                              );
                              socketService.retryMessage(
                                widget.chatId,
                                failedMessage.messageContent,
                                tempMessageId,
                              );
                            },
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            if (typingUsers.values.any((typing) => typing))
              Padding(
                padding: const EdgeInsets.only(left: 24, bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Typing...",
                    style: TextStyle(
                      color: Colors.blue.shade600,
                      fontStyle: FontStyle.italic,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            Container(
              padding: const EdgeInsets.all(20.0),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(
                  top: BorderSide(
                    color: Colors.grey.shade200,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 120),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: TextField(
                        controller: messageController,
                        keyboardType: TextInputType.multiline,
                        maxLines: 5,
                        minLines: 1,
                        onChanged: (text) {
                          if (text.isNotEmpty) {
                            handleTyping(true);
                          } else {
                            handleTyping(false);
                          }
                          setState(() {});
                        },
                        onTapOutside: (event) {
                          FocusManager.instance.primaryFocus?.unfocus();
                          handleTyping(false);
                        },
                        decoration: const InputDecoration(
                          hintText: "Type a message...",
                          hintStyle: TextStyle(fontSize: 16),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: messageController.text.trim().isEmpty
                        ? null
                        : sendMessage,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: messageController.text.trim().isEmpty
                            ? Colors.grey.shade300
                            : Colors.black,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.send,
                        color: messageController.text.trim().isEmpty
                            ? Colors.grey.shade500
                            : Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// IMPROVED MessageWidget with retry functionality
class MessageWidget extends StatelessWidget {
  final Message message;
  final bool isCurrentUser;
  final bool showAvatar;
  final String otherUserName;
  final Function(String)? onRetry;

  const MessageWidget({
    super.key,
    required this.message,
    required this.isCurrentUser,
    this.showAvatar = false,
    required this.otherUserName,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isCurrentUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 4.0),
        child: Column(
          crossAxisAlignment:
              isCurrentUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: isCurrentUser
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                if (showAvatar)
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.grey.shade200,
                        width: 1,
                      ),
                    ),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.grey.shade100,
                      child: Text(
                        otherUserName.isNotEmpty
                            ? otherUserName[0].toUpperCase()
                            : "?",
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ),
                if (showAvatar) const SizedBox(width: 10),
                Flexible(
                  child: GestureDetector(
                    onTap: message.status == 'failed' &&
                            onRetry != null &&
                            message.tempMessageId != null
                        ? () => onRetry!(message.tempMessageId!)
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      constraints: const BoxConstraints(maxWidth: 300),
                      decoration: BoxDecoration(
                        color: message.status == 'failed'
                            ? Colors.red.shade50
                            : isCurrentUser
                                ? Colors.black
                                : Colors.grey.shade100,
                        borderRadius: isCurrentUser
                            ? const BorderRadius.only(
                                topLeft: Radius.circular(24),
                                topRight: Radius.circular(24),
                                bottomLeft: Radius.circular(24),
                                bottomRight: Radius.circular(6),
                              )
                            : const BorderRadius.only(
                                topLeft: Radius.circular(6),
                                topRight: Radius.circular(24),
                                bottomLeft: Radius.circular(24),
                                bottomRight: Radius.circular(24),
                              ),
                        border: message.status == 'failed'
                            ? Border.all(color: Colors.red.shade200)
                            : null,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            message.messageContent,
                            style: TextStyle(
                              color: message.status == 'failed'
                                  ? Colors.red.shade700
                                  : isCurrentUser
                                      ? Colors.white
                                      : Colors.black87,
                              fontSize: 16,
                              height: 1.4,
                            ),
                          ),
                          if (message.status == 'failed')
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                'Tap to retry',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.red.shade600,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: isCurrentUser
                  ? const EdgeInsets.only(right: 6.0)
                  : const EdgeInsets.only(left: 42.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTimestamp(message.timestamp),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade500,
                    ),
                  ),
                  if (isCurrentUser)
                    Padding(
                      padding: const EdgeInsets.only(left: 6.0),
                      child: _buildStatusIndicator(message.status),
                    ),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(String status) {
    IconData icon;
    Color color;

    switch (status) {
      case 'read':
        icon = Icons.done_all;
        color = Colors.blue;
        break;
      case 'sent':
        icon = Icons.check;
        color = Colors.grey.shade500;
        break;
      case 'failed':
        icon = Icons.error_outline;
        color = Colors.red;
        break;
      case 'sending':
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.grey.shade500),
          ),
        );
      default:
        icon = Icons.schedule;
        color = Colors.grey.shade500;
    }

    return Icon(
      icon,
      size: 14.0,
      color: color,
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    return DateFormat('HH:mm').format(timestamp.toLocal());
  }
}
