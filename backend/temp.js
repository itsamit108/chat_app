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
            return res.status(200).json(existingUser); // Return existing user
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

        // If email is provided, filter by email
        if (email) {
            const users = await User.find({ email });
            return res.json(users);
        }

        // Otherwise, return all users
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

        // Validate chat type
        if (type !== 'private' && type !== 'group') {
            return res.status(400).json({ error: 'Chat type must be private or group' });
        }

        // For private chats, ensure exactly 2 participants
        if (type === 'private' && participants.length !== 2) {
            return res.status(400).json({ error: 'Private chats must have exactly 2 participants' });
        }

        // For group chats, ensure a group name
        if (type === 'group' && !groupName) {
            return res.status(400).json({ error: 'Group chats require a name' });
        }

        // Check if users exist
        const userIds = participants.map(p => p.participantId);
        const foundUsers = await User.find({ userId: { $in: userIds } });

        if (foundUsers.length !== userIds.length) {
            return res.status(400).json({ error: 'One or more users not found' });
        }

        // For private chats, check if chat already exists between participants
        if (type === 'private') {
            const existingChat = await Chat.findOne({
                type: 'private',
                'participants.participantId': { $all: userIds }
            });

            if (existingChat) {
                return res.json(existingChat); // Return the existing chat
            }
        }

        // Create the chat with participants
        const chatId = uuidv4();
        const formattedParticipants = participants.map(p => {
            const user = foundUsers.find(u => u.userId === p.participantId);
            return {
                participantId: p.participantId,
                participantName: user.name,
                type: p.type || 'member', // Default to member if not specified
                unreadCount: 0 // Initialize unread message count
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

        // Find all chats where the user is a participant
        const chats = await Chat.find({
            'participants.participantId': userId
        }).sort({ updatedAt: -1 });

        res.json(chats);
    } catch (error) {
        console.error('Error fetching chats:', error);
        res.status(500).json({ error: error.message });
    }
});

// Get messages for a chat with better pagination support
app.get('/api/chats/:chatId/messages', async (req, res) => {
    try {
        const { chatId } = req.params;
        const { limit = 50, before } = req.query;

        let query = { chatId };

        // If 'before' timestamp is provided, get messages before that time
        if (before) {
            query.createdAt = { $lt: new Date(before) };
        }

        const messages = await Message.find(query)
            .sort({ createdAt: -1 })
            .limit(parseInt(limit))
            .exec();

        // Send messages in reverse order (oldest first)
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

        // Check if chat exists
        const chat = await Chat.findOne({ chatId });
        if (!chat) {
            return res.status(404).json({ error: 'Chat not found' });
        }

        // Verify sender is a participant
        const isParticipant = chat.participants.some(p => p.participantId === senderId);
        if (!isParticipant) {
            return res.status(403).json({ error: 'User is not a participant in this chat' });
        }

        const messageId = uuidv4();
        const timestamp = Date.now();

        // Create the message
        const newMessage = new Message({
            chatId,
            messageId,
            senderId,
            content,
            status: "sent"
        });

        await newMessage.save();

        // Update the last message in the chat
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

    const socketToUser = {}; // socketId -> userId
    const userToSocket = {}; // userId -> socketId
    const onlineUsers = new Set(); // Set of online user IDs
    const activeChats = {}; // userId -> chatId (needed to know which chat a user is viewing)
    const chatRoomUsers = {}; // chatId -> Set of userIds (needed to know who's in which chat)
    const typingUsers = {}; // chatId -> Map of userId to timestamp (needed for typing indicators)

    io.on("connection", (socket) => {
        // Get userId from query params
        const userId = socket.handshake.query.userId;

        if (!userId) {
            console.warn(`Socket connected without userId: ${socket.id}`);
            return;
        }

        console.info(`Socket connected: ${socket.id} for user ${userId}`);

        // Track this socket
        socketToUser[socket.id] = userId;

        // If user had a previous socket, clean it up
        const previousSocketId = userToSocket[userId];
        if (previousSocketId && previousSocketId !== socket.id) {
            // Remove old socket
            const oldSocket = io.sockets.sockets.get(previousSocketId);
            if (oldSocket) {
                oldSocket.disconnect(true);
            }
            delete socketToUser[previousSocketId];
        }

        // Update socket mapping
        userToSocket[userId] = socket.id;

        // Add to online users set
        onlineUsers.add(userId);

        // Update user's lastSeen timestamp
        try {
            updateLastSeen(userId);
        } catch (err) {
            console.error(`Failed to update user lastSeen: ${err.message}`);
        }

        // Broadcast to all clients that this user is online
        socket.broadcast.emit('user-online', { userId });

        // Send list of all online users to this client
        socket.emit('online-users', Array.from(onlineUsers));

        // Handle user joining a chat room
        socket.on('join', async (data) => {
            try {
                const { userId, chatId } = data;

                if (!userId || !chatId) {
                    console.warn(`Invalid join request: ${JSON.stringify(data)}`);
                    return;
                }

                console.info(`User ${userId} joining chat ${chatId}`);

                // Join socket to the chat room
                socket.join(chatId);

                // Track which chat the user is actively viewing
                activeChats[userId] = chatId;

                // Track which users are in which chat rooms
                if (!chatRoomUsers[chatId]) {
                    chatRoomUsers[chatId] = new Set();
                }
                chatRoomUsers[chatId].add(userId);

                // Mark messages as seen when joining
                await markMessagesAsRead(userId, chatId);

                // Send the current typing status to the joining user
                if (typingUsers[chatId]) {
                    Object.keys(typingUsers[chatId]).forEach(typingUserId => {
                        if (typingUserId !== userId) {
                            socket.emit('user_typing', {
                                userId: typingUserId,
                                chatId: chatId, // Added chatId to enable global typing updates
                                isTyping: true
                            });
                        }
                    });
                }
            } catch (error) {
                console.error(`Error in join handler: ${error.message}`);
            }
        });

        // Handle user leaving a chat room
        socket.on('leave', (data) => {
            try {
                const { userId, chatId } = data;

                if (!userId || !chatId) {
                    return;
                }

                console.info(`User ${userId} leaving chat ${chatId}`);

                // Leave the room
                socket.leave(chatId);

                // Remove active chat tracking
                if (activeChats[userId] === chatId) {
                    delete activeChats[userId];
                }

                // Remove from chat room users
                if (chatRoomUsers[chatId]) {
                    chatRoomUsers[chatId].delete(userId);
                }

                // Clear typing indicator if needed
                if (typingUsers[chatId] && typingUsers[chatId][userId]) {
                    delete typingUsers[chatId][userId];
                    socket.to(chatId).emit('user_typing', {
                        userId,
                        chatId, // Added chatId to enable global typing updates
                        isTyping: false
                    });
                }
            } catch (error) {
                console.error(`Error in leave handler: ${error.message}`);
            }
        });

        // Handle sending a message
        socket.on("send_message", async (data) => {
            try {
                const { chatId, message, senderId } = data;

                if (!chatId || !message || !senderId) {
                    console.warn("Missing data for sending message: " + JSON.stringify(data));
                    return;
                }

                console.info(`Message from ${senderId} to chat ${chatId}: ${message}`);

                // Generate a unique messageId
                const messageId = uuidv4();
                const timestamp = Date.now();

                // Save message to the database
                const newMessage = new Message({
                    chatId,
                    messageId,
                    senderId,
                    content: message,
                    status: "sent"
                });

                await newMessage.save();

                // Get chat details
                const chat = await Chat.findOne({ chatId });
                if (!chat) {
                    throw new Error(`Chat not found: ${chatId}`);
                }

                // Get sender details
                const sender = chat.participants.find(p => p.participantId === senderId);
                if (!sender) {
                    throw new Error(`Sender ${senderId} not found in chat participants`);
                }

                // Increment unread count for all participants except sender
                let updatedChat = await Chat.findOneAndUpdate(
                    { chatId },
                    {
                        lastMessage: {
                            content: message,
                            messageId,
                            senderId,
                            senderName: sender.participantName,
                            timestamp
                        },
                        // Increment unread count for all participants except sender
                        $inc: {
                            'participants.$[elem].unreadCount': 1
                        }
                    },
                    {
                        arrayFilters: [{ 'elem.participantId': { $ne: senderId } }],
                        new: true
                    }
                );

                // Get the updated chat to send to users
                if (!updatedChat) {
                    updatedChat = await Chat.findOne({ chatId });
                }

                // Emit to everyone else in the chat room
                socket.to(chatId).emit('receive_message', {
                    messageId,
                    senderId,
                    messageContent: message,
                    timestamp,
                    status: "sent"
                });

                // Send chat update to all participants who are not in the chat room
                // (those who are in the chat list or elsewhere)
                chat.participants.forEach(participant => {
                    if (participant.participantId !== senderId) {
                        const participantSocketId = userToSocket[participant.participantId];
                        if (participantSocketId && (!activeChats[participant.participantId] ||
                            activeChats[participant.participantId] !== chatId)) {

                            io.to(participantSocketId).emit('chat_updated', {
                                chat: updatedChat
                            });
                        }
                    }
                });

                // Send confirmation back to sender
                socket.emit('message_confirmation', {
                    messageId,
                    originalContent: message,
                    timestamp,
                    status: "sent"
                });

                // For private chats, check if other user is ACTIVELY VIEWING this chat
                // and mark as read immediately if they are
                if (chat.type === "private" && chat.participants.length === 2) {
                    const otherParticipant = chat.participants.find(
                        p => p.participantId !== senderId
                    );

                    if (otherParticipant &&
                        activeChats[otherParticipant.participantId] === chatId) {

                        // Other user is actively viewing this chat - mark as read immediately
                        await Message.updateOne(
                            { chatId, messageId },
                            { status: "read" }
                        );

                        // Reset unread count for the other user
                        await Chat.updateOne(
                            {
                                chatId,
                                "participants.participantId": otherParticipant.participantId
                            },
                            {
                                $set: { "participants.$.unreadCount": 0 }
                            }
                        );

                        // Notify the sender that message was read
                        socket.emit('message_status_update', {
                            messageId,
                            status: "read"
                        });

                        console.info(`Message ${messageId} marked as read immediately (user is viewing chat)`);
                    }
                }

            } catch (error) {
                console.error(`Error processing message: ${error.message}`);

                // Notify sender of failure
                socket.emit('message_failed', {
                    error: error.message
                });
            }
        });

        // Handle message seen events
        socket.on("message_seen", async (data) => {
            try {
                const { userId, chatId } = data;

                if (!userId || !chatId) {
                    console.warn(`Invalid message_seen data: ${JSON.stringify(data)}`);
                    return;
                }

                console.info(`Messages seen by ${userId} in chat ${chatId}`);

                // Mark all unread messages from other users as read
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

                    // Notify the sender their message was read
                    const senderSocketId = userToSocket[message.senderId];
                    if (senderSocketId) {
                        io.to(senderSocketId).emit('message_status_update', {
                            messageId: message.messageId,
                            status: "read"
                        });

                        console.info(`Notified ${message.senderId} that message ${message.messageId} was read`);
                    }
                }

                // Reset unread count for this user in this chat
                const updatedChat = await Chat.findOneAndUpdate(
                    {
                        chatId,
                        "participants.participantId": userId
                    },
                    {
                        $set: { "participants.$.unreadCount": 0 }
                    },
                    { new: true }
                );

                // Notify this user about the updated chat (for UI consistency)
                const userSocketId = userToSocket[userId];
                if (userSocketId) {
                    io.to(userSocketId).emit('chat_updated', {
                        chat: updatedChat
                    });
                }
            } catch (error) {
                console.error(`Error in message_seen handler: ${error.message}`);
            }
        });

        // Handle typing indicators
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

                // Get chat to find participants
                Chat.findOne({ chatId }).then(chat => {
                    if (!chat) return;

                    // Broadcast typing status to all participants
                    chat.participants.forEach(participant => {
                        if (participant.participantId !== userId) {
                            const participantSocketId = userToSocket[participant.participantId];

                            if (participantSocketId) {
                                // Send typing event with chatId so it can be handled globally
                                io.to(participantSocketId).emit('user_typing', {
                                    userId,
                                    chatId,
                                    isTyping
                                });
                            }
                        }
                    });
                }).catch(err => {
                    console.error(`Error getting chat for typing event: ${err.message}`);
                });

            } catch (error) {
                console.error(`Error in typing handler: ${error.message}`);
            }
        });

        // Ping event to keep connection alive
        socket.on("ping_connection", (data) => {
            const userId = data?.userId ?? socketToUser[socket.id];
            if (userId) {
                // Update socket mappings in case they got out of sync
                socketToUser[socket.id] = userId;
                userToSocket[userId] = socket.id;

                // Send a pong back
                socket.emit("pong_connection", { success: true });
            }
        });

        // Handle disconnection
        socket.on('disconnect', async () => {
            try {
                const userId = socketToUser[socket.id];
                console.info(`Socket ${socket.id} disconnected, userId: ${userId}`);

                if (userId) {
                    // Update lastSeen time
                    try {
                        await updateLastSeen(userId);
                        console.info(`Updated lastSeen for user ${userId} on disconnect`);
                    } catch (err) {
                        console.error(`Failed to update lastSeen on disconnect: ${err.message}`);
                    }

                    // Only clear user mapping if this is the current socket for the user
                    if (userToSocket[userId] === socket.id) {
                        delete userToSocket[userId];

                        // Remove from online users after a short delay
                        // to handle page refreshes
                        setTimeout(() => {
                            // Check if the user reconnected
                            if (!userToSocket[userId]) {
                                onlineUsers.delete(userId);
                                io.emit('user-offline', { userId });
                                console.info(`User ${userId} is now offline`);

                                // Clear active chat tracking
                                delete activeChats[userId];

                                // Remove from all chat rooms
                                for (const chatId in chatRoomUsers) {
                                    if (chatRoomUsers[chatId].has(userId)) {
                                        chatRoomUsers[chatId].delete(userId);

                                        // Clear typing indicator
                                        if (typingUsers[chatId] && typingUsers[chatId][userId]) {
                                            delete typingUsers[chatId][userId];

                                            // Broadcast typing stopped to everyone in this chat
                                            io.to(chatId).emit('user_typing', {
                                                userId,
                                                chatId,
                                                isTyping: false
                                            });
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

    // Helper function to update lastSeen
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

    // Mark messages as read - returns true if any messages were updated
    async function markMessagesAsRead(userId, chatId) {
        try {
            const chat = await Chat.findOne({ chatId });

            // Only update read status for one-to-one chats
            if (chat && chat.type === "private") {
                const messages = await Message.find({
                    chatId,
                    senderId: { $ne: userId },
                    status: { $ne: "read" }
                });

                let updated = false;

                // Update each message status
                for (const message of messages) {
                    await Message.updateOne(
                        { chatId, messageId: message.messageId },
                        { status: "read" }
                    );

                    // Notify the sender that their message was read
                    const senderSocketId = userToSocket[message.senderId];
                    if (senderSocketId) {
                        io.to(senderSocketId).emit('message_status_update', {
                            messageId: message.messageId,
                            status: "read"
                        });
                    }

                    updated = true;
                }

                // Reset unread count for this user
                if (updated) {
                    const updatedChat = await Chat.findOneAndUpdate(
                        {
                            chatId,
                            "participants.participantId": userId
                        },
                        {
                            $set: { "participants.$.unreadCount": 0 }
                        },
                        { new: true }
                    );

                    // Notify the user of the updated chat for UI consistency
                    const userSocketId = userToSocket[userId];
                    if (userSocketId) {
                        io.to(userSocketId).emit('chat_updated', {
                            chat: updatedChat
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

    // Periodically clean up stale typing indicators (every 10 seconds)
    setInterval(() => {
        const now = Date.now();
        for (const chatId in typingUsers) {
            for (const userId in typingUsers[chatId]) {
                // If typing indicator is more than 5 seconds old, remove it
                if (now - typingUsers[chatId][userId] > 5000) {
                    delete typingUsers[chatId][userId];

                    // Need to broadcast typing stopped to all participants of the chat
                    Chat.findOne({ chatId }).then(chat => {
                        if (!chat) return;

                        chat.participants.forEach(participant => {
                            if (participant.participantId !== userId) {
                                const participantSocketId = userToSocket[participant.participantId];
                                if (participantSocketId) {
                                    io.to(participantSocketId).emit('user_typing', {
                                        userId,
                                        chatId,
                                        isTyping: false
                                    });
                                }
                            }
                        });
                    }).catch(err => {
                        console.error(`Error getting chat for cleaning typing indicators: ${err.message}`);
                    });
                }
            }
        }
    }, 10000);

    return io;
}

// Initialize socket.io
const io = initSocket(server);

// Start the server
const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
