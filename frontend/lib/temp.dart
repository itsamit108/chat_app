// ignore_for_file: camel_case_types, deprecated_member_use
// ignore_for_file: must_be_immutable

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart'; // Added for better date formatting
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

// API base URL - update this to your server address
const String API_BASE_URL = 'http://localhost:3000';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize shared preferences for user persistence
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
        ChangeNotifierProvider(
            create: (_) => ChatListProvider()), // Added for real-time chat list
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Chat App',
        theme: ThemeData(
          primarySwatch: Colors.blue,
          visualDensity: VisualDensity.adaptivePlatformDensity,
        ),
        home: Builder(
          builder: (context) {
            // Initialize socket service with BuildContext
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

// Enhanced UserPreferences class to handle user registration data
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

// Chat model to handle chat data
class ChatModel {
  final String chatId;
  final String type;
  final String? groupName;
  final List<ChatParticipant> participants;
  final DateTime updatedAt;
  final LastMessage? lastMessage;
  final Map<String, bool> typingUsers; // Map of userId to typing status

  ChatModel({
    required this.chatId,
    required this.type,
    this.groupName,
    required this.participants,
    required this.updatedAt,
    this.lastMessage,
    Map<String, bool>? typingUsers,
  }) : typingUsers = typingUsers ?? {};

  factory ChatModel.fromJson(Map<String, dynamic> json) {
    // Parse participants
    List<ChatParticipant> participants = [];
    if (json['participants'] != null) {
      for (var participant in json['participants']) {
        participants.add(ChatParticipant.fromJson(participant));
      }
    }

    // Parse last message if available
    LastMessage? lastMessage;
    if (json['lastMessage'] != null &&
        json['lastMessage'] is Map &&
        json['lastMessage'].isNotEmpty) {
      lastMessage = LastMessage.fromJson(json['lastMessage']);
    }

    // Parse updatedAt timestamp
    DateTime updatedAt;
    if (json['updatedAt'] != null) {
      try {
        updatedAt = DateTime.parse(json['updatedAt']);
      } catch (e) {
        updatedAt = DateTime.now();
      }
    } else {
      updatedAt = DateTime.now();
    }

    return ChatModel(
      chatId: json['chatId'] ?? '',
      type: json['type'] ?? 'private',
      groupName: json['groupName'],
      participants: participants,
      updatedAt: updatedAt,
      lastMessage: lastMessage,
    );
  }

  // Get other participant (for private chats)
  ChatParticipant getOtherParticipant(String currentUserId) {
    return participants.firstWhere(
      (p) => p.participantId != currentUserId,
      orElse: () => participants.first,
    );
  }

  // Check if someone is typing in this chat
  bool get isTyping => typingUsers.values.any((typing) => typing);

  // Get unread count for current user
  int getUnreadCount(String userId) {
    final participant = participants.firstWhere(
      (p) => p.participantId == userId,
      orElse: () => ChatParticipant(
        participantId: '',
        participantName: '',
        unreadCount: 0,
      ),
    );
    return participant.unreadCount;
  }

  // Create a copy with updated typing status
  ChatModel copyWithTyping(String userId, bool isTyping) {
    Map<String, bool> newTypingUsers = Map.from(typingUsers);
    if (isTyping) {
      newTypingUsers[userId] = true;
    } else {
      newTypingUsers.remove(userId);
    }

    return ChatModel(
      chatId: chatId,
      type: type,
      groupName: groupName,
      participants: participants,
      updatedAt: updatedAt,
      lastMessage: lastMessage,
      typingUsers: newTypingUsers,
    );
  }
}

// Chat participant model
class ChatParticipant {
  final String participantId;
  final String participantName;
  final String type;
  final int unreadCount;

  ChatParticipant({
    required this.participantId,
    required this.participantName,
    this.type = 'member',
    this.unreadCount = 0,
  });

  factory ChatParticipant.fromJson(Map<String, dynamic> json) {
    return ChatParticipant(
      participantId: json['participantId'] ?? '',
      participantName: json['participantName'] ?? '',
      type: json['type'] ?? 'member',
      unreadCount: json['unreadCount'] ?? 0,
    );
  }
}

// Last message model
class LastMessage {
  final String messageId;
  final String senderId;
  final String? senderName;
  final String content;
  final DateTime timestamp;

  LastMessage({
    required this.messageId,
    required this.senderId,
    this.senderName,
    required this.content,
    required this.timestamp,
  });

  factory LastMessage.fromJson(Map<String, dynamic> json) {
    // Handle timestamp which might be a string or number
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

    return LastMessage(
      messageId: json['messageId'] ?? '',
      senderId: json['senderId'] ?? '',
      senderName: json['senderName'],
      content: json['content'] ?? '',
      timestamp: timestamp,
    );
  }
}

// Provider for Chat List
class ChatListProvider extends ChangeNotifier {
  List<ChatModel> _chats = [];
  bool _isLoading = false;

  List<ChatModel> get chats => _chats;
  bool get isLoading => _isLoading;

  // Set new chat list (e.g., from API response)
  void setChats(List<ChatModel> chats) {
    _chats = chats;
    _sortChats();
    notifyListeners();
  }

  // Add or update a single chat
  void updateChat(ChatModel chat) {
    int index = _chats.indexWhere((c) => c.chatId == chat.chatId);
    if (index != -1) {
      // Preserve typing status when updating
      Map<String, bool> existingTypingUsers = _chats[index].typingUsers;
      ChatModel updatedChat = ChatModel(
        chatId: chat.chatId,
        type: chat.type,
        groupName: chat.groupName,
        participants: chat.participants,
        updatedAt: chat.updatedAt,
        lastMessage: chat.lastMessage,
        typingUsers: existingTypingUsers,
      );
      _chats[index] = updatedChat;
    } else {
      _chats.add(chat);
    }
    _sortChats();
    notifyListeners();
  }

  // Handle new message
  void handleNewMessage(ChatModel updatedChat) {
    int index = _chats.indexWhere((c) => c.chatId == updatedChat.chatId);
    if (index != -1) {
      _chats[index] = updatedChat;
    } else {
      _chats.add(updatedChat);
    }
    _sortChats();
    notifyListeners();
  }

  // Update typing status for a chat
  void updateTypingStatus(String chatId, String userId, bool isTyping) {
    int index = _chats.indexWhere((c) => c.chatId == chatId);
    if (index != -1) {
      _chats[index] = _chats[index].copyWithTyping(userId, isTyping);
      notifyListeners();
    }
  }

  // Clear all typing indicators (on app restart)
  void clearAllTypingIndicators() {
    for (int i = 0; i < _chats.length; i++) {
      if (_chats[i].typingUsers.isNotEmpty) {
        _chats[i] = ChatModel(
          chatId: _chats[i].chatId,
          type: _chats[i].type,
          groupName: _chats[i].groupName,
          participants: _chats[i].participants,
          updatedAt: _chats[i].updatedAt,
          lastMessage: _chats[i].lastMessage,
          typingUsers: {},
        );
      }
    }
    notifyListeners();
  }

  // Set loading state
  void setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  // Sort chats by last activity (messages, typing)
  void _sortChats() {
    _chats.sort((a, b) {
      // Typing chats always come first
      if (a.isTyping && !b.isTyping) return -1;
      if (!a.isTyping && b.isTyping) return 1;

      // Then sort by last message time
      DateTime aTime = a.lastMessage?.timestamp ?? a.updatedAt;
      DateTime bTime = b.lastMessage?.timestamp ?? b.updatedAt;
      return bTime.compareTo(aTime); // Newest first
    });
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

// Message model
class Message {
  final String messageId;
  final String senderId;
  final String messageContent;
  final DateTime timestamp;
  String status; // 'sent', 'read', 'failed'

  Message({
    required this.messageId,
    required this.senderId,
    required this.messageContent,
    required this.timestamp,
    this.status = 'sent',
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    // Handle timestamp which might be a string or number
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
    );
  }
}

class ChatMessagesProvider extends ChangeNotifier {
  List<Message> _messages = [];

  List<Message> get messages => _messages;

  void addMessage(Message message) {
    // Check for duplicates before adding
    final isDuplicate = _messages.any((m) =>
        m.messageId == message.messageId ||
        (m.senderId == message.senderId &&
            m.messageContent == message.messageContent &&
            (m.timestamp.difference(message.timestamp).inSeconds.abs() < 1)));

    if (!isDuplicate) {
      _messages = [..._messages, message];
      notifyListeners();
    }
  }

  void addMessages(List<Message> messages) {
    if (messages.isEmpty) return;

    // Create a set of existing message IDs for quick lookup
    final existingIds = _messages.map((m) => m.messageId).toSet();

    // Filter out messages that already exist
    final newMessages =
        messages.where((msg) => !existingIds.contains(msg.messageId)).toList();

    if (newMessages.isEmpty) return;

    // Add new messages and sort
    _messages = [..._messages, ...newMessages];

    // Sort messages by timestamp in ascending order
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    notifyListeners();
  }

  void updateMessageStatus(String messageId, String status) {
    final updatedMessages = _messages.map((message) {
      if (message.messageId == messageId) {
        message.status = status;
      }
      return message;
    }).toList();

    _messages = updatedMessages;
    notifyListeners();
  }

  void confirmMessage(String content, String newMessageId,
      DateTime serverTimestamp, String status) {
    final now = DateTime.now();
    bool updated = false;

    final newMessages = _messages.map((message) {
      if (!updated &&
          message.messageContent == content &&
          now.difference(message.timestamp).inMinutes < 1) {
        updated = true;
        return Message(
          messageId: newMessageId,
          senderId: message.senderId,
          messageContent: message.messageContent,
          timestamp: serverTimestamp,
          status: status,
        );
      }
      return message;
    }).toList();

    if (updated) {
      _messages = newMessages;
      notifyListeners();
    }
  }

  void clearMessages() {
    _messages = [];
    notifyListeners();
  }
}

// Socket service
class SocketService {
  static final SocketService _instance = SocketService._internal();
  IO.Socket? socket;
  bool isInitialized = false;
  Timer? pingTimer;
  BuildContext? _context;
  String? activeChat;
  final Set<String> _handledMessageSeen =
      {}; // Track processed message_seen events

  factory SocketService() {
    return _instance;
  }

  SocketService._internal();

  void initSocket(BuildContext context) {
    if (isInitialized) return;
    _context = context;

    print("Initializing socket connection");
    final userId = UserPreferences.getUserId();

    // Check if user is logged in, if not, don't initialize socket
    if (userId.isEmpty) return;

    socket = IO.io(
        API_BASE_URL,
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .setPath('/socket.io/')
            .disableAutoConnect()
            .setQuery({'userId': userId})
            .build());

    socket!.connect();

    socket?.onConnect((_) {
      print('Socket connected successfully');

      // Clear all typing indicators when reconnecting
      if (_context != null) {
        Provider.of<ChatListProvider>(_context!, listen: false)
            .clearAllTypingIndicators();
      }
    });

    socket?.onDisconnect((_) {
      print('Socket disconnected');
    });

    socket?.onConnectError((error) {
      print('Socket connection error: $error');
    });

    // Set up online status listeners
    socket?.on('online-users', (data) {
      if (data is List) {
        final users = Set<String>.from(data);
        Future(() {
          if (_context != null) {
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
          if (_context != null) {
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
          if (_context != null) {
            Provider.of<OnlineUsersProvider>(_context!, listen: false)
                .removeUser(userId);
          }
        });
        print('User offline: $userId');
      }
    });

    // Listen for chat updates
    socket?.on('chat_updated', (data) {
      if (data != null && data['chat'] != null) {
        try {
          final chat = ChatModel.fromJson(data['chat']);
          if (_context != null) {
            Provider.of<ChatListProvider>(_context!, listen: false)
                .updateChat(chat);
          }
        } catch (e) {
          print('Error parsing chat update: $e');
        }
      }
    });

    // Listen for typing indicators on the global level
    socket?.on('user_typing', (data) {
      if (data != null &&
          data['userId'] != null &&
          data['chatId'] != null &&
          _context != null) {
        final userId = data['userId'];
        final chatId = data['chatId'];
        final isTyping = data['isTyping'] ?? false;

        if (userId != UserPreferences.getUserId()) {
          Provider.of<ChatListProvider>(_context!, listen: false)
              .updateTypingStatus(chatId, userId, isTyping);

          // If we are in this specific chat, update the message screen too
          if (activeChat == chatId && _context != null) {
            final state =
                _context!.findAncestorStateOfType<_MessageScreenState>();
            if (state != null) {
              state.updateTypingStatus(userId, isTyping);
            }
          }
        }
      }
    });

    // Keep-alive ping
    pingTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (socket?.connected == true) {
        socket?.emit("ping_connection", {'userId': userId});
      } else {
        reconnectSocket();
      }
    });

    isInitialized = true;
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
  }

  void leaveChat(String chatId) {
    if (socket?.connected == true) {
      final userId = UserPreferences.getUserId();
      socket?.emit('leave', {'userId': userId, 'chatId': chatId});
      if (activeChat == chatId) {
        activeChat = null;
      }
    }
  }

  void sendMessage(String chatId, String message) {
    if (!isInitialized || socket == null) return;
    final userId = UserPreferences.getUserId();
    socket?.emit('send_message',
        {'senderId': userId, 'chatId': chatId, 'message': message});
  }

  void markMessagesAsSeen(String chatId) {
    if (!isInitialized || socket == null) return;

    final userId = UserPreferences.getUserId();
    // Create a unique key for this event to avoid duplicates
    final seenEventKey =
        '$userId:$chatId:${DateTime.now().millisecondsSinceEpoch ~/ 1000}';

    // Only emit if we haven't handled this combination recently
    if (!_handledMessageSeen.contains(seenEventKey)) {
      _handledMessageSeen.add(seenEventKey);
      socket?.emit('message_seen', {'userId': userId, 'chatId': chatId});

      // Remove from handled set after 2 seconds to prevent flooding
      Future.delayed(const Duration(seconds: 2), () {
        _handledMessageSeen.remove(seenEventKey);
      });
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
  final bool _isLoading = true;
  bool _isRefreshing = false;
  String _searchQuery = "";

  // Login dialog controllers
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  bool _isLoggingIn = false;
  final _loginFormKey = GlobalKey<FormState>();

  // Get socket service
  final socketService = SocketService();

  @override
  void initState() {
    super.initState();
    _checkUserLogin();

    // Setup socket event listeners
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupSocketListeners();
    });
  }

  void _setupSocketListeners() {
    // Socket is initialized in main, we just need to ensure we're listening
    if (socketService.socket == null) return;

    // Chat updates are already handled in the SocketService class
  }

  void _checkUserLogin() async {
    if (UserPreferences.getUserId().isEmpty) {
      // Show login dialog if not logged in
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showLoginDialog();
      });
    } else {
      // User is logged in, fetch data
      _fetchChats();
      _fetchUsers();
    }
  }

  void _showLoginDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Welcome to Chat App'),
        content: Form(
          key: _loginFormKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
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
                decoration: const InputDecoration(labelText: 'Email'),
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
          TextButton(
            onPressed: _isLoggingIn ? null : _registerUser,
            child: _isLoggingIn
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Login'),
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
      // First check if user with this email already exists
      final checkResponse = await http.get(
        Uri.parse(
            '$API_BASE_URL/api/users?email=${_emailController.text.trim()}'),
      );

      if (checkResponse.statusCode == 200) {
        final List existingUsers = json.decode(checkResponse.body);

        if (existingUsers.isNotEmpty) {
          // User exists, use that account
          final userData = existingUsers.first;
          await UserPreferences.setUserData(
            userData['userId'],
            userData['name'],
            userData['email'],
          );

          Navigator.of(context).pop(); // Close dialog
          _fetchChats();
          _fetchUsers();

          // Initialize socket after login
          socketService.initSocket(context);
          return;
        }
      }

      // No existing user, create a new one
      final response = await http.post(
        Uri.parse('$API_BASE_URL/api/users'),
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

        Navigator.of(context).pop(); // Close dialog
        _fetchChats();
        _fetchUsers();

        // Initialize socket after login
        socketService.initSocket(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to register: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoggingIn = false;
        });
      }
    }
  }

  // Format timestamp to display actual time instead of relative time
  String _formatTime(DateTime dateTime) {
    // If it's today, show time
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

    if (messageDate == today) {
      // Today, show time only
      return DateFormat('h:mm a').format(dateTime.toLocal());
    } else if (messageDate == yesterday) {
      // Yesterday
      return "Yesterday";
    } else if (now.difference(messageDate).inDays < 7) {
      // Within last week, show day name
      return DateFormat('EEEE').format(dateTime);
    } else {
      // Older, show date
      return DateFormat('MMM d').format(dateTime);
    }
  }

  Future<void> _fetchChats({bool showLoading = true}) async {
    if (showLoading && !_isRefreshing) {
      Provider.of<ChatListProvider>(context, listen: false).setLoading(true);
    }

    try {
      final userId = UserPreferences.getUserId();
      final response = await http.get(
        Uri.parse('$API_BASE_URL/api/users/$userId/chats'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List<ChatModel> chats = [];

        for (var chatJson in data) {
          try {
            chats.add(ChatModel.fromJson(chatJson));
          } catch (e) {
            print("Error parsing chat: $e");
          }
        }

        // Update the provider
        Provider.of<ChatListProvider>(context, listen: false).setChats(chats);
      } else {
        print("Error fetching chats: ${response.statusCode}");
      }
    } catch (e) {
      print("Error in chat screen: $e");
    } finally {
      Provider.of<ChatListProvider>(context, listen: false).setLoading(false);
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _fetchUsers() async {
    try {
      final response = await http.get(Uri.parse('$API_BASE_URL/api/users'));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List<UserModel> users = [];

        for (var user in data) {
          // Skip the current user
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

  List<UserModel> _allUsers = [];

  Future<void> _createChat(UserModel user) async {
    setState(() {
      _isRefreshing = true;
    });

    try {
      final currentUserId = UserPreferences.getUserId();
      final currentUserName = UserPreferences.getUserName();

      final response = await http.post(
        Uri.parse('$API_BASE_URL/api/chats'),
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

        // First refresh the chat list
        await _fetchChats(showLoading: false);

        // Then navigate to the message screen
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
            .then((_) => _fetchChats(showLoading: false)); // Refresh on return
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to create chat')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await UserPreferences.clearUserData();
              SocketService.disconnectSocket();
              _showLoginDialog();
            },
          ),
        ],
      ),
      body: Consumer<ChatListProvider>(
        builder: (context, chatListProvider, _) {
          final isLoading = chatListProvider.isLoading;
          final allChats = chatListProvider.chats;

          // Filter chats based on search query
          final filteredChats = _searchQuery.isEmpty
              ? allChats
              : allChats.where((chat) {
                  String currentUserId = UserPreferences.getUserId();
                  var otherParticipant =
                      chat.getOtherParticipant(currentUserId);
                  return otherParticipant.participantName
                      .toLowerCase()
                      .contains(_searchQuery.toLowerCase());
                }).toList();

          return isLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    // Users horizontal list
                    if (_allUsers.isNotEmpty)
                      SizedBox(
                        height: 110, // Slightly increased height
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: _allUsers.length,
                          itemBuilder: (context, index) {
                            final user = _allUsers[index];
                            final isOnline =
                                Provider.of<OnlineUsersProvider>(context)
                                    .isUserOnline(user.userId);

                            // Make entire container clickable
                            return GestureDetector(
                              onTap: () => _createChat(user),
                              child: Container(
                                width: 80,
                                margin: const EdgeInsets.all(8),
                                child: Column(
                                  mainAxisSize:
                                      MainAxisSize.min, // Prevent overflow
                                  children: [
                                    Stack(
                                      children: [
                                        CircleAvatar(
                                          radius: 30,
                                          child: Text(
                                            user.name.isNotEmpty
                                                ? user.name[0].toUpperCase()
                                                : "?",
                                            style: const TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        if (isOnline)
                                          Positioned(
                                            right: 0,
                                            bottom: 0,
                                            child: Container(
                                              width: 15,
                                              height: 15,
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
                                    const SizedBox(height: 4),
                                    Text(
                                      user.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),

                    // Search bar
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: TextField(
                        onChanged: (value) {
                          setState(() {
                            _searchQuery = value;
                          });
                        },
                        decoration: InputDecoration(
                          hintText: 'Search chats...',
                          prefixIcon: const Icon(Icons.search),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),

                    // Chat list
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: () => _fetchChats(showLoading: false),
                        child: filteredChats.isEmpty
                            ? const Center(
                                child: Text(
                                  "No chats yet. Start a conversation with someone above!",
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : ListView.builder(
                                itemCount: filteredChats.length,
                                itemBuilder: (context, index) {
                                  final chat = filteredChats[index];
                                  String currentUserId =
                                      UserPreferences.getUserId();

                                  // Get the other participant
                                  final otherParticipant =
                                      chat.getOtherParticipant(currentUserId);
                                  final otherParticipantId =
                                      otherParticipant.participantId;
                                  final otherParticipantName =
                                      otherParticipant.participantName;

                                  // Check if user is online
                                  final isOnline =
                                      Provider.of<OnlineUsersProvider>(context)
                                          .isUserOnline(otherParticipantId);

                                  // Get last message info
                                  final lastMessage = chat.lastMessage;
                                  final hasLastMessage = lastMessage != null;
                                  final DateTime timeStamp = hasLastMessage
                                      ? lastMessage.timestamp
                                      : chat.updatedAt;
                                  final String messageContent =
                                      hasLastMessage ? lastMessage.content : "";

                                  // Check if this chat has unread messages
                                  final unreadCount =
                                      chat.getUnreadCount(currentUserId);

                                  // Check if someone is typing
                                  final isTyping = chat.isTyping;

                                  return ListTile(
                                    leading: Stack(
                                      children: [
                                        CircleAvatar(
                                          child: Text(
                                            otherParticipantName.isNotEmpty
                                                ? otherParticipantName[0]
                                                    .toUpperCase()
                                                : "?",
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
                                    title: Text(
                                      otherParticipantName,
                                      style: TextStyle(
                                        fontWeight: unreadCount > 0
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                    subtitle: isTyping
                                        ? const Text(
                                            "Typing...",
                                            style: TextStyle(
                                              fontStyle: FontStyle.italic,
                                              color: Colors.green,
                                            ),
                                          )
                                        : Text(
                                            messageContent.isEmpty
                                                ? "No messages yet"
                                                : messageContent,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontWeight: unreadCount > 0
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                            ),
                                          ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (messageContent.isNotEmpty)
                                          Text(
                                            _formatTime(timeStamp),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: unreadCount > 0
                                                  ? Colors.blue
                                                  : Colors.grey,
                                              fontWeight: unreadCount > 0
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                            ),
                                          ),
                                        if (unreadCount > 0)
                                          Container(
                                            margin: const EdgeInsets.only(left: 8),
                                            padding: const EdgeInsets.all(6),
                                            decoration: const BoxDecoration(
                                              color: Colors.blue,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Text(
                                              unreadCount.toString(),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                              ),
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
                                            senderId: otherParticipantId,
                                            name: otherParticipantName,
                                          ),
                                        ),
                                      ).then((_) => _fetchChats(
                                          showLoading:
                                              false)); // Refresh on return
                                    },
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
  Map<String, bool> typingUsers = {}; // Track who is typing
  Timer? typingTimer;
  bool isTyping = false;

  // Pagination variables
  bool _isLoadingMore = false;
  bool _hasMoreMessages = true;
  final int _messagesPerPage = 50;
  bool _isFirstLoad = true;
  String? _beforeTimestamp;

  // Get socket service
  final socketService = SocketService();

  // Track if we've marked messages as seen to avoid duplicates
  bool _hasMarkedAsSeen = false;

  @override
  void initState() {
    super.initState();
    currentUserId = UserPreferences.getUserId();

    // Make sure socket is initialized
    if (!socketService.isInitialized) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        socketService.initSocket(context);
      });
    }

    // Setup socket listeners
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setupSocketListeners();
      socketService.joinChat(widget.chatId);

      // Mark messages as seen only once when the screen loads
      if (!_hasMarkedAsSeen) {
        socketService.markMessagesAsSeen(widget.chatId);
        _hasMarkedAsSeen = true;
      }
    });

    // Add scroll listener for pagination
    _scrollController.addListener(_scrollListener);

    // Load initial messages
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<ChatMessagesProvider>(context, listen: false).clearMessages();
      getMessages();
    });
  }

  // Function to format date for day headers
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
      // Return weekday for dates within the last week
      return DateFormat('EEEE')
          .format(date); // Use DateFormat for consistent day names
    } else {
      // Return formatted date
      return DateFormat('MMMM d, y').format(date); // Full date format
    }
  }

  void _scrollListener() {
    // Check if we're near the top of the list and need to load more messages
    if (_scrollController.position.pixels <=
            _scrollController.position.minScrollExtent + 50 &&
        !_isLoadingMore &&
        _hasMoreMessages) {
      _loadMoreMessages();
    }
  }

  void setupSocketListeners() {
    // Get the socket
    final socket = socketService.socket;
    if (socket == null) return;

    // Clear existing listeners to prevent duplicates
    socket.off('receive_message');
    socket.off('message_status_update');
    socket.off('user_typing');
    socket.off('message_confirmation');
    socket.off('message_failed');

    // Listen for incoming messages
    socket.on('receive_message', (data) {
      if (mounted && data['chatId'] == widget.chatId) {
        // Parse timestamp properly
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
        );

        Provider.of<ChatMessagesProvider>(context, listen: false)
            .addMessage(message);

        // Mark message as seen since we're actively viewing this chat
        if (!_hasMarkedAsSeen) {
          socketService.markMessagesAsSeen(widget.chatId);
          _hasMarkedAsSeen = true;
        }

        _scrollToBottom();
      }
    });

    // Listen for message status updates (read receipts)
    socket.on('message_status_update', (data) {
      if (mounted && data['messageId'] != null && data['status'] != null) {
        Provider.of<ChatMessagesProvider>(context, listen: false)
            .updateMessageStatus(data['messageId'], data['status']);
      }
    });

    // Listen for typing indicators
    socket.on('user_typing', (data) {
      if (mounted &&
          data['userId'] != null &&
          data['chatId'] == widget.chatId &&
          data['userId'] != currentUserId) {
        updateTypingStatus(data['userId'], data['isTyping']);
      }
    });

    // Listen for message confirmation (our message was successfully sent)
    socket.on('message_confirmation', (data) {
      if (mounted && data['messageId'] != null) {
        Provider.of<ChatMessagesProvider>(context, listen: false)
            .confirmMessage(
                data['originalContent'],
                data['messageId'],
                DateTime.fromMillisecondsSinceEpoch(data['timestamp'] is int
                    ? data['timestamp']
                    : int.parse(data['timestamp'])),
                data['status'] ?? 'sent');
      }
    });
  }

  // Method to update typing status - can be called from outside
  void updateTypingStatus(String userId, bool isTyping) {
    setState(() {
      typingUsers[userId] = isTyping;
    });
  }

  void handleTyping(bool typing) {
    if (isTyping != typing) {
      isTyping = typing;
      socketService.sendTypingStatus(widget.chatId, typing);
    }

    // Reset typing timer
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

    // Build the URL with pagination parameters
    var url =
        '$API_BASE_URL/api/chats/${widget.chatId}/messages?limit=$_messagesPerPage';
    if (_beforeTimestamp != null) {
      url += '&before=$_beforeTimestamp';
    }

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final List data = json.decode(response.body);

        // Update pagination state
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

        // Add messages to provider
        Provider.of<ChatMessagesProvider>(context, listen: false)
            .addMessages(parsedMessages);

        // If this is the first load, scroll to bottom and mark as seen
        if (_isFirstLoad) {
          _scrollToBottom(animated: false);
          _isFirstLoad = false;

          if (!_hasMarkedAsSeen) {
            socketService.markMessagesAsSeen(widget.chatId);
            _hasMarkedAsSeen = true;
          }
        }
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

  void sendMessage() {
    if (messageController.text.isEmpty) return;

    final messageText = messageController.text.trim();
    final tempMessageId = DateTime.now().millisecondsSinceEpoch.toString();

    // Add message to UI immediately with a temporary ID
    final tempMessage = Message(
      messageId: tempMessageId,
      senderId: currentUserId,
      messageContent: messageText,
      timestamp: DateTime.now(),
      status: 'sent',
    );

    Provider.of<ChatMessagesProvider>(context, listen: false)
        .addMessage(tempMessage);

    // Send via socket service
    socketService.sendMessage(widget.chatId, messageText);

    // Clear input and scroll to bottom
    messageController.clear();
    handleTyping(false);
    _scrollToBottom();
  }

  @override
  void dispose() {
    // Clean up
    if (isTyping) {
      socketService.sendTypingStatus(widget.chatId, false);
    }

    // Leave the chat room
    socketService.leaveChat(widget.chatId);
    typingTimer?.cancel();
    _scrollController.removeListener(_scrollListener);
    messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Check if user is online
    final isOnline =
        Provider.of<OnlineUsersProvider>(context).isUserOnline(widget.senderId);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(widget.name),
            const SizedBox(width: 8),
            if (isOnline)
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        // Added SafeArea to prevent overflows
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
                      // Show loading indicator at the top
                      if (_isLoadingMore && index == 0) {
                        return Container(
                          height: 50,
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: const Center(
                            child: CircularProgressIndicator(),
                          ),
                        );
                      }

                      // Show "No more messages" indicator
                      if (!_hasMoreMessages && !_isLoadingMore && index == 0) {
                        return Container(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: const Center(
                            child: Text(
                              "No more messages",
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        );
                      }

                      // Adjust index based on whether we're showing indicators
                      final messageIndex = index -
                          (_isLoadingMore ? 1 : 0) -
                          (!_hasMoreMessages && !_isLoadingMore ? 1 : 0);

                      if (messageIndex < 0 || messageIndex >= messages.length) {
                        return const SizedBox.shrink();
                      }

                      final message = messages[messageIndex];
                      final isCurrentUser = message.senderId == currentUserId;

                      // Check if a date header is needed
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
                              margin: const EdgeInsets.symmetric(vertical: 8.0),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Text(
                                    _formatDateForHeader(message.timestamp),
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
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
                            senderId: widget.senderId,
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),

            // Show typing indicator
            if (typingUsers.values.any((typing) => typing))
              const Padding(
                padding: EdgeInsets.only(left: 20, bottom: 5),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Typing...",
                    style: TextStyle(
                      color: Colors.grey,
                      fontStyle: FontStyle.italic,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),

            // Message input area
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxHeight:
                                100, // Reduced max height to prevent overflow
                          ),
                          child: TextField(
                            controller: messageController,
                            keyboardType: TextInputType.multiline,
                            maxLines: 4,
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
                              border: InputBorder.none,
                              isDense: true,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: messageController.text.trim().isEmpty
                                ? Colors.grey
                                : Colors.blue,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Icon(
                            Icons.send_outlined,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        onPressed: messageController.text.trim().isEmpty
                            ? null
                            : sendMessage,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MessageWidget extends StatelessWidget {
  final Message message;
  final bool isCurrentUser;
  final bool showAvatar;
  final String senderId;

  const MessageWidget({
    super.key,
    required this.message,
    required this.isCurrentUser,
    this.showAvatar = false,
    required this.senderId,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isCurrentUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment:
              isCurrentUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, // Added to prevent overflow
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, // Added to prevent overflow
              mainAxisAlignment: isCurrentUser
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                if (showAvatar)
                  CircleAvatar(
                    radius: 16,
                    child: Text(
                      senderId.isNotEmpty ? senderId[0].toUpperCase() : "?",
                    ),
                  ),
                if (showAvatar) const SizedBox(width: 8),
                Flexible(
                  // Wrapped in Flexible to prevent overflow
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    constraints: const BoxConstraints(maxWidth: 250),
                    decoration: BoxDecoration(
                      color: isCurrentUser ? Colors.blue : Colors.grey.shade200,
                      borderRadius: isCurrentUser
                          ? const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              topRight: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            )
                          : const BorderRadius.only(
                              bottomLeft: Radius.circular(16),
                              topRight: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                            ),
                    ),
                    child: Text(
                      message.messageContent,
                      style: TextStyle(
                        color: isCurrentUser ? Colors.white : Colors.black87,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2), // Added spacing
            Padding(
              padding: isCurrentUser
                  ? const EdgeInsets.only(right: 4.0)
                  : const EdgeInsets.only(left: 40.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTimestamp(message.timestamp),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),

                  // Only show status for current user's messages
                  if (isCurrentUser)
                    Padding(
                      padding: const EdgeInsets.only(left: 4.0),
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
        color = Colors.grey;
        break;
      case 'failed':
        icon = Icons.error_outline;
        color = Colors.red;
        break;
      default:
        icon = Icons.schedule;
        color = Colors.grey;
    }

    return Icon(
      icon,
      size: 14.0,
      color: color,
    );
  }

  // Format time as HH:MM (not relative time)
  String _formatTimestamp(DateTime timestamp) {
    return DateFormat('h:mm a').format(timestamp.toLocal());
  }
}
