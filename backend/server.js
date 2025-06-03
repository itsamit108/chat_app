// server.js
import express from 'express';
import http from 'http';
import { Server as SocketIOServer } from 'socket.io';
import mongoose from 'mongoose';
import { v4 as uuidv4 } from 'uuid';
import cors from 'cors';

const app = express();
const server = http.createServer(app);

// Middleware
app.use(cors());
app.use(express.json());

// Connect to MongoDB
mongoose.connect('mongodb://localhost:27017/chatapp', {
    useNewUrlParser: true,
    useUnifiedTopology: true
})
    .then(() => console.log('MongoDB connected'))
    .catch(err => console.error('MongoDB connection error:', err));

// Define Schemas
const userSchema = new mongoose.Schema({
    userId: {
        type: String,
        required: true,
        unique: true
    },
    name: {
        type: String,
        required: true
    },
    email: {
        type: String,
        required: true,
        unique: true
    },
    lastSeen: {
        type: Number,
        default: Date.now
    }
}, { timestamps: true });

const chatSchema = new mongoose.Schema({
    chatId: {
        type: String,
        required: true,
        unique: true
    },
    type: {
        type: String,
        enum: ["private", "group"],
        required: true
    },
    groupName: {
        type: String
    },
    participants: [{
        participantId: {
            type: String,
            required: true
        },
        participantName: String,
        type: {
            type: String,
            enum: ["admin", "member"],
            default: "member"
        },
        unreadCount: {
            type: Number,
            default: 0
        }
    }],
    lastMessage: {
        content: String,
        messageId: String,
        senderId: String,
        senderName: String,
        timestamp: Number
    }
}, { timestamps: true });

const messageSchema = new mongoose.Schema({
    chatId: {
        type: String,
        required: true
    },
    messageId: {
        type: String,
        required: true
    },
    senderId: {
        type: String,
        required: true
    },
    content: {
        type: String,
        required: true
    },
    isDeleted: {
        type: Boolean,
        default: false
    },
    isEdited: {
        type: Boolean,
        default: false
    },
    status: {
        type: String,
        enum: ["sent", "read", "failed"],
        default: "sent"
    }
}, { timestamps: true });

// Create indexes
messageSchema.index({ chatId: 1, createdAt: -1 });
chatSchema.index({ 'participants.participantId': 1 });

// Create models
const User = mongoose.model('User', userSchema);
const Chat = mongoose.model('Chat', chatSchema);
const Message = mongoose.model('Message', messageSchema);

// API routes
app.post('/api/users', async (req, res) => {
    try {
        const { name, email } = req.body;

        if (!name || !email) {
            return res.status(400).json({ error: 'Name and email are required' });
        }

        // Check if user with this email already exists
        const existingUser = await User.findOne({ email });
        if (existingUser) {
            return res.status(200).json(existingUser);
        }

        const userId = uuidv4();
        const newUser = new User({
            userId,
            name,
            email
        });

        await newUser.save();
        res.status(201).json(newUser);
    } catch (error) {
        console.error('Error creating user:', error);
        res.status(500).json({ error: error.message });
    }
});

app.get('/api/users', async (req, res) => {
    try {
        const { email } = req.query;

        if (email) {
            const users = await User.find({ email });
            return res.json(users);
        }

        const users = await User.find();
        res.json(users);
    } catch (error) {
        console.error('Error fetching users:', error);
        res.status(500).json({ error: error.message });
    }
});

app.get('/api/users/:userId', async (req, res) => {
    try {
        const { userId } = req.params;
        const user = await User.findOne({ userId });

        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }

        res.json(user);
    } catch (error) {
        console.error('Error fetching user:', error);
        res.status(500).json({ error: error.message });
    }
});

// Create a new chat
app.post('/api/chats', async (req, res) => {
    try {
        const { type, participants, groupName } = req.body;

        if (!type || !participants || participants.length < 2) {
            return res.status(400).json({ error: 'Type and at least two participants are required' });
        }

        if (type !== 'private' && type !== 'group') {
            return res.status(400).json({ error: 'Chat type must be private or group' });
        }

        if (type === 'private' && participants.length !== 2) {
            return res.status(400).json({ error: 'Private chats must have exactly 2 participants' });
        }

        if (type === 'group' && !groupName) {
            return res.status(400).json({ error: 'Group chats require a name' });
        }

        const userIds = participants.map(p => p.participantId);
        const foundUsers = await User.find({ userId: { $in: userIds } });

        if (foundUsers.length !== userIds.length) {
            return res.status(400).json({ error: 'One or more users not found' });
        }

        if (type === 'private') {
            const existingChat = await Chat.findOne({
                type: 'private',
                'participants.participantId': { $all: userIds }
            });

            if (existingChat) {
                return res.json(existingChat);
            }
        }

        const chatId = uuidv4();
        const formattedParticipants = participants.map(p => {
            const user = foundUsers.find(u => u.userId === p.participantId);
            return {
                participantId: p.participantId,
                participantName: user.name,
                type: p.type || 'member',
                unreadCount: 0
            };
        });

        const newChat = new Chat({
            chatId,
            type,
            groupName: type === 'group' ? groupName : undefined,
            participants: formattedParticipants
        });

        await newChat.save();
        res.status(201).json(newChat);
    } catch (error) {
        console.error('Error creating chat:', error);
        res.status(500).json({ error: error.message });
    }
});

// Get chats for a user
app.get('/api/users/:userId/chats', async (req, res) => {
    try {
        const { userId } = req.params;

        const chats = await Chat.find({
            'participants.participantId': userId
        }).sort({ updatedAt: -1 });

        res.json(chats);
    } catch (error) {
        console.error('Error fetching chats:', error);
        res.status(500).json({ error: error.message });
    }
});

// Get messages for a chat with pagination
app.get('/api/chats/:chatId/messages', async (req, res) => {
    try {
        const { chatId } = req.params;
        const { limit = 50, before } = req.query;

        let query = { chatId };

        if (before) {
            query.createdAt = { $lt: new Date(before) };
        }

        const messages = await Message.find(query)
            .sort({ createdAt: -1 })
            .limit(parseInt(limit))
            .exec();

        res.json(messages.reverse());
    } catch (error) {
        console.error('Error fetching messages:', error);
        res.status(500).json({ error: error.message });
    }
});

// Send a message
app.post('/api/chats/:chatId/messages', async (req, res) => {
    try {
        const { chatId } = req.params;
        const { content, senderId } = req.body;

        if (!content || !senderId) {
            return res.status(400).json({ error: 'Content and senderId are required' });
        }

        const chat = await Chat.findOne({ chatId });
        if (!chat) {
            return res.status(404).json({ error: 'Chat not found' });
        }

        const isParticipant = chat.participants.some(p => p.participantId === senderId);
        if (!isParticipant) {
            return res.status(403).json({ error: 'User is not a participant in this chat' });
        }

        const messageId = uuidv4();
        const timestamp = Date.now();

        const newMessage = new Message({
            chatId,
            messageId,
            senderId,
            content,
            status: "sent"
        });

        await newMessage.save();

        const sender = chat.participants.find(p => p.participantId === senderId);
        await Chat.updateOne(
            { chatId },
            {
                lastMessage: {
                    content,
                    messageId,
                    senderId,
                    senderName: sender.participantName,
                    timestamp
                }
            }
        );

        res.status(201).json(newMessage);
    } catch (error) {
        console.error('Error sending message:', error);
        res.status(500).json({ error: error.message });
    }
});

// Socket.io implementation
function initSocket(server) {
    const io = new SocketIOServer(server, {
        cors: {
            origin: "*",
            methods: ["GET", "POST"],
        },
    });

    const socketToUser = {};
    const userToSocket = {};
    const onlineUsers = new Set();
    const activeChats = {};
    const chatRoomUsers = {};
    const typingUsers = {};

    io.on("connection", (socket) => {
        const userId = socket.handshake.query.userId;

        if (!userId) {
            console.warn(`Socket connected without userId: ${socket.id}`);
            return;
        }

        console.info(`Socket connected: ${socket.id} for user ${userId}`);

        socketToUser[socket.id] = userId;

        const previousSocketId = userToSocket[userId];
        if (previousSocketId && previousSocketId !== socket.id) {
            const oldSocket = io.sockets.sockets.get(previousSocketId);
            if (oldSocket) {
                oldSocket.disconnect(true);
            }
            delete socketToUser[previousSocketId];
        }

        userToSocket[userId] = socket.id;
        onlineUsers.add(userId);

        try {
            updateLastSeen(userId);
        } catch (err) {
            console.error(`Failed to update user lastSeen: ${err.message}`);
        }

        socket.join(`user:${userId}`);
        socket.broadcast.emit('user-online', { userId });
        socket.emit('online-users', Array.from(onlineUsers));

        // Subscribe to chat list updates
        socket.on('subscribe_chat_list', async (data) => {
            try {
                console.info(`User ${userId} subscribed to chat list updates`);

                const chats = await Chat.find({
                    'participants.participantId': userId
                });

                for (const chat of chats) {
                    if (typingUsers[chat.chatId]) {
                        Object.entries(typingUsers[chat.chatId]).forEach(([typingUserId, timestamp]) => {
                            if (typingUserId !== userId && (Date.now() - timestamp) < 5000) {
                                socket.emit('chat_typing', {
                                    chatId: chat.chatId,
                                    userId: typingUserId,
                                    isTyping: true
                                });
                            }
                        });
                    }
                }
            } catch (error) {
                console.error(`Error in subscribe_chat_list handler: ${error.message}`);
            }
        });

        socket.on('join', async (data) => {
            try {
                const { userId, chatId } = data;

                if (!userId || !chatId) {
                    console.warn(`Invalid join request: ${JSON.stringify(data)}`);
                    return;
                }

                console.info(`User ${userId} joining chat ${chatId}`);

                socket.join(chatId);
                activeChats[userId] = chatId;

                if (!chatRoomUsers[chatId]) {
                    chatRoomUsers[chatId] = new Set();
                }
                chatRoomUsers[chatId].add(userId);

                await markMessagesAsRead(userId, chatId);

                if (typingUsers[chatId]) {
                    Object.keys(typingUsers[chatId]).forEach(typingUserId => {
                        if (typingUserId !== userId) {
                            socket.emit('user_typing', {
                                userId: typingUserId,
                                isTyping: true
                            });
                        }
                    });
                }
            } catch (error) {
                console.error(`Error in join handler: ${error.message}`);
            }
        });

        socket.on('leave', (data) => {
            try {
                const { userId, chatId } = data;

                if (!userId || !chatId) {
                    return;
                }

                console.info(`User ${userId} leaving chat ${chatId}`);

                socket.leave(chatId);

                if (activeChats[userId] === chatId) {
                    delete activeChats[userId];
                }

                if (chatRoomUsers[chatId]) {
                    chatRoomUsers[chatId].delete(userId);
                }

                if (typingUsers[chatId] && typingUsers[chatId][userId]) {
                    delete typingUsers[chatId][userId];
                    socket.to(chatId).emit('user_typing', {
                        userId,
                        isTyping: false
                    });

                    notifyChatParticipantsOfTyping(chatId, userId, false);
                }
            } catch (error) {
                console.error(`Error in leave handler: ${error.message}`);
            }
        });

        socket.on("send_message", async (data) => {
            try {
                const { chatId, message, senderId, tempMessageId } = data;

                if (!chatId || !message || !senderId) {
                    console.warn("Missing data for sending message: " + JSON.stringify(data));
                    return;
                }

                console.info(`Message from ${senderId} to chat ${chatId}: ${message} (temp: ${tempMessageId})`);

                const messageId = uuidv4();
                const timestamp = Date.now();

                const newMessage = new Message({
                    chatId,
                    messageId,
                    senderId,
                    content: message,
                    status: "sent"
                });

                await newMessage.save();

                const chat = await Chat.findOne({ chatId });
                if (!chat) {
                    throw new Error(`Chat not found: ${chatId}`);
                }

                const sender = chat.participants.find(p => p.participantId === senderId);
                if (!sender) {
                    throw new Error(`Sender ${senderId} not found in chat participants`);
                }

                // Update unread counts for participants not active in this chat
                const updatedParticipants = [];
                for (const participant of chat.participants) {
                    if (participant.participantId !== senderId) {
                        // Check if user is actively viewing this chat
                        const isActiveInChat = (activeChats[participant.participantId] === chatId);

                        if (!isActiveInChat) {
                            // Increment unread count only if user is not actively viewing the chat
                            updatedParticipants.push({
                                ...participant.toObject(),
                                unreadCount: (participant.unreadCount || 0) + 1
                            });
                        } else {
                            // User is actively viewing chat, keep unread count at 0
                            updatedParticipants.push({
                                ...participant.toObject(),
                                unreadCount: 0
                            });
                        }
                    } else {
                        // Sender's unread count remains the same
                        updatedParticipants.push(participant.toObject());
                    }
                }

                // Update chat with new last message and unread counts
                await Chat.updateOne(
                    { chatId },
                    {
                        lastMessage: {
                            content: message,
                            messageId,
                            senderId,
                            senderName: sender.participantName,
                            timestamp
                        },
                        participants: updatedParticipants,
                        updatedAt: new Date()
                    }
                );

                // Send message to chat room
                socket.to(chatId).emit('receive_message', {
                    messageId,
                    senderId,
                    messageContent: message,
                    timestamp,
                    status: "sent"
                });

                // Confirm message to sender with temp ID mapping
                socket.emit('message_confirmation', {
                    messageId,
                    tempMessageId: tempMessageId || null,
                    originalContent: message,
                    timestamp,
                    status: "sent"
                });

                // Notify ALL participants about chat list updates
                for (const participant of chat.participants) {
                    const updatedParticipant = updatedParticipants.find(
                        p => p.participantId === participant.participantId
                    );

                    const socketId = userToSocket[participant.participantId];
                    if (socketId) {
                        io.to(socketId).emit('chat_update', {
                            chatId,
                            lastMessage: {
                                content: message,
                                senderId,
                                senderName: sender.participantName,
                                timestamp
                            },
                            unreadCount: updatedParticipant?.unreadCount || 0
                        });

                        console.info(`Sent chat_update to ${participant.participantId} for chat ${chatId}`);
                    }
                }

                // For private chats, handle read status if other user is viewing
                if (chat.type === "private" && chat.participants.length === 2) {
                    const otherParticipant = chat.participants.find(
                        p => p.participantId !== senderId
                    );

                    if (otherParticipant &&
                        activeChats[otherParticipant.participantId] === chatId) {

                        await Message.updateOne(
                            { chatId, messageId },
                            { status: "read" }
                        );

                        socket.emit('message_status_update', {
                            messageId,
                            status: "read"
                        });

                        console.info(`Message ${messageId} marked as read immediately (user is viewing chat)`);
                    }
                }

            } catch (error) {
                console.error(`Error processing message: ${error.message}`);
                socket.emit('message_failed', {
                    error: error.message,
                    tempMessageId: data.tempMessageId || null
                });
            }
        });

        socket.on("message_seen", async (data) => {
            try {
                const { userId, chatId } = data;

                if (!userId || !chatId) {
                    console.warn(`Invalid message_seen data: ${JSON.stringify(data)}`);
                    return;
                }

                console.info(`Messages seen by ${userId} in chat ${chatId}`);

                const messages = await Message.find({
                    chatId,
                    senderId: { $ne: userId },
                    status: { $ne: "read" }
                });

                for (const message of messages) {
                    await Message.updateOne(
                        { chatId, messageId: message.messageId },
                        { status: "read" }
                    );

                    const senderSocketId = userToSocket[message.senderId];
                    if (senderSocketId) {
                        io.to(senderSocketId).emit('message_status_update', {
                            messageId: message.messageId,
                            status: "read"
                        });

                        console.info(`Notified ${message.senderId} that message ${message.messageId} was read`);
                    }
                }

                // Reset unread count to 0 for this user in this chat
                await Chat.updateOne(
                    { chatId, 'participants.participantId': userId },
                    { $set: { 'participants.$.unreadCount': 0 } }
                );

                const userSocketId = userToSocket[userId];
                if (userSocketId) {
                    io.to(userSocketId).emit('chat_update', {
                        chatId,
                        unreadCount: 0
                    });
                }
            } catch (error) {
                console.error(`Error in message_seen handler: ${error.message}`);
            }
        });

        socket.on("typing", (data) => {
            try {
                const { userId, chatId, isTyping } = data;

                if (!userId || !chatId) {
                    return;
                }

                if (!typingUsers[chatId]) {
                    typingUsers[chatId] = {};
                }

                if (isTyping) {
                    typingUsers[chatId][userId] = Date.now();
                } else {
                    delete typingUsers[chatId][userId];
                }

                socket.to(chatId).emit('user_typing', {
                    userId,
                    isTyping
                });

                notifyChatParticipantsOfTyping(chatId, userId, isTyping);

            } catch (error) {
                console.error(`Error in typing handler: ${error.message}`);
            }
        });

        socket.on("ping_connection", (data) => {
            const userId = data?.userId ?? socketToUser[socket.id];
            if (userId) {
                socketToUser[socket.id] = userId;
                userToSocket[userId] = socket.id;
                socket.emit("pong_connection", { success: true });
            }
        });

        socket.on('disconnect', async () => {
            try {
                const userId = socketToUser[socket.id];
                console.info(`Socket ${socket.id} disconnected, userId: ${userId}`);

                if (userId) {
                    try {
                        await updateLastSeen(userId);
                        console.info(`Updated lastSeen for user ${userId} on disconnect`);
                    } catch (err) {
                        console.error(`Failed to update lastSeen on disconnect: ${err.message}`);
                    }

                    if (userToSocket[userId] === socket.id) {
                        delete userToSocket[userId];

                        setTimeout(() => {
                            if (!userToSocket[userId]) {
                                onlineUsers.delete(userId);
                                io.emit('user-offline', { userId });
                                console.info(`User ${userId} is now offline`);

                                delete activeChats[userId];

                                for (const chatId in chatRoomUsers) {
                                    if (chatRoomUsers[chatId].has(userId)) {
                                        chatRoomUsers[chatId].delete(userId);

                                        if (typingUsers[chatId] && typingUsers[chatId][userId]) {
                                            delete typingUsers[chatId][userId];
                                            io.to(chatId).emit('user_typing', {
                                                userId,
                                                isTyping: false
                                            });

                                            notifyChatParticipantsOfTyping(chatId, userId, false);
                                        }
                                    }
                                }
                            }
                        }, 5000);
                    }
                }

                delete socketToUser[socket.id];

            } catch (error) {
                console.error(`Error in disconnect handler: ${error.message}`);
            }
        });
    });

    async function updateLastSeen(userId) {
        try {
            await User.updateOne(
                { userId },
                { lastSeen: Date.now() }
            );
        } catch (error) {
            console.error(`Failed to update lastSeen for ${userId}: ${error.message}`);
            throw error;
        }
    }

    function notifyChatParticipantsOfTyping(chatId, typingUserId, isTyping) {
        Chat.findOne({ chatId }).then(chat => {
            if (!chat) return;

            for (const participant of chat.participants) {
                if (participant.participantId !== typingUserId &&
                    activeChats[participant.participantId] !== chatId) {

                    const socketId = userToSocket[participant.participantId];
                    if (socketId) {
                        io.to(socketId).emit('chat_typing', {
                            chatId,
                            userId: typingUserId,
                            isTyping
                        });
                    }
                }
            }
        }).catch(error => {
            console.error(`Error notifying chat participants of typing: ${error.message}`);
        });
    }

    async function markMessagesAsRead(userId, chatId) {
        try {
            const chat = await Chat.findOne({ chatId });

            if (chat && chat.type === "private") {
                const messages = await Message.find({
                    chatId,
                    senderId: { $ne: userId },
                    status: { $ne: "read" }
                });

                let updated = false;

                for (const message of messages) {
                    await Message.updateOne(
                        { chatId, messageId: message.messageId },
                        { status: "read" }
                    );

                    const senderSocketId = userToSocket[message.senderId];
                    if (senderSocketId) {
                        io.to(senderSocketId).emit('message_status_update', {
                            messageId: message.messageId,
                            status: "read"
                        });
                    }

                    updated = true;
                }

                if (updated) {
                    // Reset unread count to 0 for this user in this chat
                    await Chat.updateOne(
                        { chatId, 'participants.participantId': userId },
                        { $set: { 'participants.$.unreadCount': 0 } }
                    );

                    const userSocketId = userToSocket[userId];
                    if (userSocketId) {
                        io.to(userSocketId).emit('chat_update', {
                            chatId,
                            unreadCount: 0
                        });
                    }

                    console.info(`Marked ${messages.length} messages as read by ${userId} in chat ${chatId}`);
                }

                return updated;
            }

            return false;
        } catch (error) {
            console.error(`Error marking messages as read: ${error.message}`);
            return false;
        }
    }

    setInterval(() => {
        const now = Date.now();
        for (const chatId in typingUsers) {
            for (const userId in typingUsers[chatId]) {
                if (now - typingUsers[chatId][userId] > 5000) {
                    const wasTyping = typingUsers[chatId][userId] !== undefined;
                    delete typingUsers[chatId][userId];

                    if (wasTyping) {
                        io.to(chatId).emit('user_typing', {
                            userId,
                            isTyping: false
                        });

                        notifyChatParticipantsOfTyping(chatId, userId, false);
                    }
                }
            }
        }
    }, 10000);

    return io;
}

const io = initSocket(server);

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
