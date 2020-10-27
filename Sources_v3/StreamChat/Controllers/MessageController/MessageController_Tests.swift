//
// Copyright © 2020 Stream.io Inc. All rights reserved.
//

import CoreData
@testable import StreamChat
import XCTest

final class MessageController_Tests: StressTestCase {
    private var env: TestEnvironment!
    private var client: ChatClient!
    
    private var currentUserId: UserId!
    private var messageId: MessageId!
    private var cid: ChannelId!
    
    private var controller: ChatMessageController!
    private var controllerCallbackQueueID: UUID!
    private var callbackQueueID: UUID { controllerCallbackQueueID }
    
    // MARK: - Setup
    
    override func setUp() {
        super.setUp()
        
        env = TestEnvironment()
        client = _ChatClient.mock
        
        currentUserId = .unique
        messageId = .unique
        cid = .unique
        
        controllerCallbackQueueID = UUID()
        controller = ChatMessageController(client: client, cid: cid, messageId: messageId, environment: env.controllerEnvironment)
        controller.callbackQueue = .testQueue(withId: controllerCallbackQueueID)
    }
    
    override func tearDown() {
        env.messageUpdater?.cleanUp()
        
        controllerCallbackQueueID = nil
        currentUserId = nil
        messageId = nil
        cid = nil
        
        AssertAsync {
            Assert.canBeReleased(&controller)
            Assert.canBeReleased(&client)
            Assert.canBeReleased(&env)
        }

        super.tearDown()
    }
    
    // MARK: - Controller
    
    func test_controllerIsCreatedCorrectly() {
        // Create a controller with specific `cid` and `messageId`
        let controller = client.messageController(cid: cid, messageId: messageId)
        
        // Assert controller has correct `cid`
        XCTAssertEqual(controller.cid, cid)
        // Assert controller has correct `messageId`
        XCTAssertEqual(controller.messageId, messageId)
    }

    func test_initialState() {
        // Assert client is assigned correctly
        XCTAssertTrue(controller.client === client)
        
        // Assert initial state is correct
        XCTAssertEqual(controller.state, .initialized)
        
        // Assert message is nil
        XCTAssertNil(controller.message)
    }
    
    // MARK: - Synchronize
    
    func test_synchronize_forwardsUpdaterError() throws {
        // Simulate `synchronize` call
        var completionError: Error?
        controller.synchronize {
            completionError = $0
        }
        
        // Simulate netrwork response with the error
        let networkError = TestError()
        env.messageUpdater.getMessage_completion?(networkError)
        
        AssertAsync {
            // Assert netrwork error is propogated
            Assert.willBeEqual(completionError as? TestError, networkError)
            // Assert netrwork error is propogated
            Assert.willBeEqual(self.controller.state, .remoteDataFetchFailed(ClientError(with: networkError)))
        }
    }
    
    func test_synchronize_changesStateCorrectly_ifNoErrorsHappen() throws {
        // Simulate `synchronize` call
        var completionError: Error?
        var completionCalled = false
        controller.synchronize {
            completionError = $0
            completionCalled = true
        }
        
        // Assert controller is in `localDataFetched` state
        XCTAssertEqual(controller.state, .localDataFetched)
        
        // Simulate netrwork response with the error
        env.messageUpdater.getMessage_completion?(nil)
        
        AssertAsync {
            // Assert completion is called
            Assert.willBeTrue(completionCalled)
            // Assert completion is called without any error
            Assert.staysTrue(completionError == nil)
            // Assert controller is in `remoteDataFetched` state
            Assert.willBeEqual(self.controller.state, .remoteDataFetched)
        }
    }
    
    // MARK: - Synchronize
    
    func test_messageIsUpToDate_withoutSynchronizeCall() throws {
        // Assert message is `nil` initially and start observing DB
        XCTAssertNil(controller.message)
        
        let messageLocalText: String = .unique
        
        // Create current user in the database
        try client.databaseContainer.createCurrentUser(id: currentUserId)
        
        // Create message in that matches controller's `messageId`
        try client.databaseContainer.createMessage(id: messageId, authorId: currentUserId, cid: cid, text: messageLocalText)
        
        // Assert message is fetched from the database and has correct field values
        var message = try XCTUnwrap(controller.message)
        XCTAssertEqual(message.id, messageId)
        XCTAssertEqual(message.text, messageLocalText)
        
        // Simulate response from the backend with updated `text`, update the local message in the databse
        let messagePayload: MessagePayload<DefaultExtraData> = .dummy(
            messageId: messageId,
            authorUserId: currentUserId,
            text: .unique
        )
        try client.databaseContainer.writeSynchronously { session in
            try session.saveMessage(payload: messagePayload, for: self.cid)
        }
        
        // Assert the controller's `message` is up-to-date
        message = try XCTUnwrap(controller.message)
        XCTAssertEqual(message.id, messageId)
        XCTAssertEqual(message.text, messagePayload.text)
    }
    
    // MARK: - Order
    
    func test_replies_haveCorrectOrder() throws {
        // Insert parent message
        try client.databaseContainer.createMessage(id: messageId, authorId: .unique, cid: cid, text: "Parent")
        
        // Insert 2 replies for parent message
        let reply1: MessagePayload<DefaultExtraData> = .dummy(
            messageId: .unique,
            parentId: messageId,
            showReplyInChannel: false,
            authorUserId: .unique
        )
        
        let reply2: MessagePayload<DefaultExtraData> = .dummy(
            messageId: .unique,
            parentId: messageId,
            showReplyInChannel: false,
            authorUserId: .unique
        )
        
        try client.databaseContainer.writeSynchronously {
            try $0.saveMessage(payload: reply1, for: self.cid)
            try $0.saveMessage(payload: reply2, for: self.cid)
        }
        
        // Set top-to-bottom ordering
        controller.listOrdering = .topToBottom
        
        // Check the order of replies is correct
        let topToBottomIds = [reply1, reply2].sorted { $0.createdAt > $1.createdAt }.map(\.id)
        XCTAssertEqual(controller.replies.map(\.id), topToBottomIds)
        
        // Set bottom-to-top ordering
        controller.listOrdering = .bottomToTop
        
        // Check the order of replies is correct
        let bottomToTopIds = [reply1, reply2].sorted { $0.createdAt < $1.createdAt }.map(\.id)
        XCTAssertEqual(controller.replies.map(\.id), bottomToTopIds)
    }

    // MARK: - Delegate

    func test_delegate_isAssignedCorrectly() {
        let delegate = TestDelegate(expectedQueueId: callbackQueueID)

        // Set the delegate
        controller.delegate = delegate

        // Assert the delegate is assigned correctly
        XCTAssert(controller.delegate === delegate)
    }
    
    func test_settingDelegate_leadsToFetchingLocalDataa() {
        // Check initial state
        XCTAssertEqual(controller.state, .initialized)
        
        // Set the delegate
        let delegate = TestDelegate(expectedQueueId: callbackQueueID)
        controller.delegate = delegate
        
        // Assert state changed
        AssertAsync.willBeEqual(controller.state, .localDataFetched)
    }

    func test_delegate_isNotifiedAboutStateChanges() throws {
        // Set the delegate
        let delegate = TestDelegate(expectedQueueId: callbackQueueID)
        controller.delegate = delegate
        
        // Assert delegate is notified about state changes
        AssertAsync.willBeEqual(delegate.state, .localDataFetched)

        // Synchronize
        controller.synchronize()
            
        // Simulate network call response
        env.messageUpdater.getMessage_completion?(nil)
        
        // Assert delegate is notified about state changes
        AssertAsync.willBeEqual(delegate.state, .remoteDataFetched)
    }

    func test_genericDelegate_isNotifiedAboutStateChanges() throws {
        // Set the generic delegate
        let delegate = TestDelegateGeneric(expectedQueueId: callbackQueueID)
        controller.setDelegate(delegate)
        
        // Assert delegate is notified about state changes
        AssertAsync.willBeEqual(delegate.state, .localDataFetched)

        // Synchronize
        controller.synchronize()
        
        // Simulate network call response
        env.messageUpdater.getMessage_completion?(nil)
        
        // Assert delegate is notified about state changes
        AssertAsync.willBeEqual(delegate.state, .remoteDataFetched)
    }

    func test_delegate_isNotifiedAboutCreatedMessage() throws {
        // Create current user in the database
        try client.databaseContainer.createCurrentUser(id: currentUserId)
        
        // Create channel in the database
        try client.databaseContainer.createChannel(cid: cid)
        
        // Set the delegate
        let delegate = TestDelegate(expectedQueueId: callbackQueueID)
        controller.delegate = delegate
        
        // Simulate `synchronize` call
        controller.synchronize()

        // Simulate response from a backend with a message that doesn't exist locally
        let messagePayload: MessagePayload<DefaultExtraData> = .dummy(
            messageId: messageId,
            authorUserId: currentUserId
        )
        try client.databaseContainer.writeSynchronously { session in
            try session.saveMessage(payload: messagePayload, for: self.cid)
        }
        env.messageUpdater.getMessage_completion?(nil)
        
        // Assert `create` entity change is received by the delegate
        AssertAsync {
            Assert.willBeEqual(delegate.didChangeMessage_change?.fieldChange(\.id), .create(messagePayload.id))
            Assert.willBeEqual(delegate.didChangeMessage_change?.fieldChange(\.text), .create(messagePayload.text))
        }
    }
    
    func test_delegate_isNotifiedAboutUpdatedMessage() throws {
        let initialMessageText: String = .unique

        // Create current user in the database
        try client.databaseContainer.createCurrentUser(id: currentUserId)
        
        // Create channel in the database
        try client.databaseContainer.createChannel(cid: cid)
        
        // Create message in the database with `initialMessageText`
        try client.databaseContainer.createMessage(id: messageId, authorId: currentUserId, cid: cid, text: initialMessageText)
        
        // Set the delegate
        let delegate = TestDelegate(expectedQueueId: callbackQueueID)
        controller.delegate = delegate
        
        // Simulate `synchronize` call
        controller.synchronize()
        
        // Simulate response from a backend with a message that exists locally but has out-dated text
        let messagePayload: MessagePayload<DefaultExtraData> = .dummy(
            messageId: messageId,
            authorUserId: currentUserId,
            text: "new text"
        )
        try client.databaseContainer.writeSynchronously { session in
            try session.saveMessage(payload: messagePayload, for: self.cid)
        }
        env.messageUpdater.getMessage_completion?(nil)
        
        // Assert `update` entity change is received by the delegate
        AssertAsync {
            Assert.willBeEqual(delegate.didChangeMessage_change?.fieldChange(\.id), .update(messagePayload.id))
            Assert.willBeEqual(delegate.didChangeMessage_change?.fieldChange(\.text), .update(messagePayload.text))
        }
    }
    
    func test_delegate_isNotifiedAboutRepliesChanges() throws {
        // Create current user in the database
        try client.databaseContainer.createCurrentUser(id: currentUserId)
        
        // Create channel in the database
        try client.databaseContainer.createChannel(cid: cid)
        
        // Create parent message
        try client.databaseContainer.createMessage(id: messageId, authorId: currentUserId, cid: cid)
        
        // Set the delegate
        let delegate = TestDelegate(expectedQueueId: callbackQueueID)
        controller.delegate = delegate
        
        // Simulate `synchronize` call
        controller.synchronize()
        
        // Add reply to DB
        let reply: MessagePayload<DefaultExtraData> = .dummy(
            messageId: .unique,
            parentId: messageId,
            showReplyInChannel: false,
            authorUserId: .unique
        )
        
        var replyDTO: MessageDTO?
        try client.databaseContainer.writeSynchronously { session in
            replyDTO = try session.saveMessage(payload: reply, for: self.cid)
        }
    
        // Assert `insert` entity change is received by the delegate
        AssertAsync.willBeEqual(
            delegate.didChangeReplies_changes,
            [.insert((replyDTO?.asModel())!, index: [0, 0])]
        )
    }
    
    // MARK: - Delete message
    
    func test_deleteMessage_propogatesError() {
        // Simulate `deleteMessage` call and catch the completion
        var completionError: Error?
        controller.deleteMessage { [callbackQueueID] in
            AssertTestQueue(withId: callbackQueueID)
            completionError = $0
        }
        
        // Simulate network response with the error
        let networkError = TestError()
        env.messageUpdater.deleteMessage_completion?(networkError)
        
        // Assert error is propogated
        AssertAsync.willBeEqual(completionError as? TestError, networkError)
    }
    
    func test_deleteMessage_propogatesNilError() {
        // Simulate `deleteMessage` call and catch the completion
        var completionCalled = false
        controller.deleteMessage { [callbackQueueID] in
            AssertTestQueue(withId: callbackQueueID)
            XCTAssertNil($0)
            completionCalled = true
        }
        
        // Simulate successful network response
        env.messageUpdater.deleteMessage_completion?(nil)
        
        // Assert completion is called
        AssertAsync.willBeTrue(completionCalled)
    }
    
    func test_deleteMessage_callsMessageUpdater_withCorrectValues() {
        // Simulate `deleteMessage` call
        controller.deleteMessage()
        
        // Assert messageUpdater is called with correct `messageId`
        XCTAssertEqual(env.messageUpdater.deleteMessage_messageId, controller.messageId)
    }
    
    // MARK: - Edit message
    
    func test_editMessage_propogatesError() {
        // Simulate `editMessage` call and catch the completion
        var completionError: Error?
        controller.editMessage(text: .unique) { [callbackQueueID] in
            AssertTestQueue(withId: callbackQueueID)
            completionError = $0
        }
        
        // Simulate network response with the error
        let networkError = TestError()
        env.messageUpdater.editMessage_completion?(networkError)
        
        // Assert error is propogated
        AssertAsync.willBeEqual(completionError as? TestError, networkError)
    }
    
    func test_editMessage_propogatesNilError() {
        // Simulate `editMessage` call and catch the completion
        var completionCalled = false
        controller.editMessage(text: .unique) { [callbackQueueID] in
            AssertTestQueue(withId: callbackQueueID)
            XCTAssertNil($0)
            completionCalled = true
        }
        
        // Simulate successful network response
        env.messageUpdater.editMessage_completion?(nil)
        
        // Assert completion is called
        AssertAsync.willBeTrue(completionCalled)
    }
    
    func test_editMessage_callsMessageUpdater_withCorrectValues() {
        let updatedText: String = .unique
        
        // Simulate `editMessage` call and catch the completion
        controller.editMessage(text: updatedText)
        
        // Assert message updater is called with correct `messageId` and `text`
        XCTAssertEqual(env.messageUpdater.editMessage_messageId, controller.messageId)
        XCTAssertEqual(env.messageUpdater.editMessage_text, updatedText)
    }
    
    // MARK: - Flag message
    
    func test_flag_propogatesError() {
        // Simulate `flag` call and catch the completion.
        var completionError: Error?
        controller.flag { [callbackQueueID] in
            AssertTestQueue(withId: callbackQueueID)
            completionError = $0
        }
        
        // Simulate network response with the error.
        let networkError = TestError()
        env.messageUpdater!.flagMessage_completion!(networkError)
        
        // Assert error is propogated.
        AssertAsync.willBeEqual(completionError as? TestError, networkError)
    }
    
    func test_flag_propogatesNilError() {
        // Simulate `flag` call and catch the completion.
        var completionIsCalled = false
        controller.flag { [callbackQueueID] error in
            // Assert callback queue is correct.
            AssertTestQueue(withId: callbackQueueID)
            // Assert there is no error.
            XCTAssertNil(error)
            completionIsCalled = true
        }
        
        // Simulate successful network response.
        env.messageUpdater!.flagMessage_completion!(nil)
        
        // Assert completion is called.
        AssertAsync.willBeTrue(completionIsCalled)
    }
    
    func test_flag_callsUpdater_withCorrectValues() {
        // Simulate `flag` call.
        controller.flag()
        
        // Assert updater is called with correct `flag`.
        XCTAssertEqual(env.messageUpdater!.flagMessage_flag, true)
        // Assert updater is called with correct `messageId`.
        XCTAssertEqual(env.messageUpdater!.flagMessage_messageId, controller.messageId)
        // Assert updater is called with correct `cid`.
        XCTAssertEqual(env.messageUpdater!.flagMessage_cid, controller.cid)
    }
    
    func test_flag_keepsControllerAlive() {
        // Simulate `flag` call.
        controller.flag()
        
        // Create a weak ref and release a controller.
        weak var weakController = controller
        controller = nil
        
        // Assert controller is kept alive.
        AssertAsync.staysTrue(weakController != nil)
    }
    
    // MARK: - Unflag message
    
    func test_unflag_propogatesError() {
        // Simulate `unflag` call and catch the completion.
        var completionError: Error?
        controller.unflag { [callbackQueueID] in
            AssertTestQueue(withId: callbackQueueID)
            completionError = $0
        }
        
        // Simulate network response with the error.
        let networkError = TestError()
        env.messageUpdater!.flagMessage_completion!(networkError)
        
        // Assert error is propogated.
        AssertAsync.willBeEqual(completionError as? TestError, networkError)
    }
    
    func test_unflag_propogatesNilError() {
        // Simulate `unflag` call and catch the completion.
        var completionIsCalled = false
        controller.unflag { [callbackQueueID] error in
            // Assert callback queue is correct.
            AssertTestQueue(withId: callbackQueueID)
            // Assert there is no error.
            XCTAssertNil(error)
            completionIsCalled = true
        }
        
        // Simulate successful network response.
        env.messageUpdater!.flagMessage_completion!(nil)
        
        // Assert completion is called.
        AssertAsync.willBeTrue(completionIsCalled)
    }
    
    func test_unflag_callsUpdater_withCorrectValues() {
        // Simulate `unflag` call.
        controller.unflag()
        
        // Assert updater is called with correct `flag`.
        XCTAssertEqual(env.messageUpdater!.flagMessage_flag, false)
        // Assert updater is called with correct `messageId`.
        XCTAssertEqual(env.messageUpdater!.flagMessage_messageId, controller.messageId)
        // Assert updater is called with correct `cid`.
        XCTAssertEqual(env.messageUpdater!.flagMessage_cid, controller.cid)
    }
    
    func test_unflag_keepsControllerAlive() {
        // Simulate `unflag` call.
        controller.unflag()
        
        // Create a weak ref and release a controller.
        weak var weakController = controller
        controller = nil
        
        // Assert controller is kept alive.
        AssertAsync.staysTrue(weakController != nil)
    }
    
    // MARK: - Create new reply
    
    func test_createNewReply_callsChannelUpdater() {
        let newMessageId: MessageId = .unique
        
        // New message values
        let text: String = .unique
//        let command: String = .unique
//        let arguments: String = .unique
        let showReplyInChannel = true
        let extraData: DefaultExtraData.Message = .defaultValue
        
        // Simulate `createNewReply` calls and catch the completion
        var completionCalled = false
        controller.createNewReply(
            text: text,
//            command: command,
//            arguments: arguments,
            showReplyInChannel: showReplyInChannel,
            extraData: extraData
        ) { [callbackQueueID] result in
            AssertTestQueue(withId: callbackQueueID)
            AssertResultSuccess(result, newMessageId)
            completionCalled = true
        }
        
        // Completion shouldn't be called yet
        XCTAssertFalse(completionCalled)
        
        // Simulate successful update
        env.messageUpdater?.createNewReply_completion?(.success(newMessageId))
        
        // Completion should be called
        AssertAsync.willBeTrue(completionCalled)
        
        XCTAssertEqual(env.messageUpdater?.createNewReply_cid, cid)
        XCTAssertEqual(env.messageUpdater?.createNewReply_text, text)
//        XCTAssertEqual(env.channelUpdater?.createNewMessage_command, command)
//        XCTAssertEqual(env.channelUpdater?.createNewMessage_arguments, arguments)
        XCTAssertEqual(env.messageUpdater?.createNewReply_parentMessageId, messageId)
        XCTAssertEqual(env.messageUpdater?.createNewReply_showReplyInChannel, showReplyInChannel)
        XCTAssertEqual(env.messageUpdater?.createNewReply_extraData, extraData)
    }
    
    func test_createNewReply_keepsControllerAlive() {
        // Simulate `createNewReply` call.
        controller.createNewReply(text: "Reply")
        
        // Create a weak reference and release a controller.
        weak var weakController = controller
        controller = nil
        
        // Assert controller is kept alive
        AssertAsync.staysTrue(weakController != nil)
    }
    
    // MARK: - Load replies
    
    func test_loadPreviousReplies_propagatesError() {
        // Simulate `loadPreviousReplies` call and catch the completion
        var completionError: Error?
        controller.loadPreviousReplies { [callbackQueueID] in
            AssertTestQueue(withId: callbackQueueID)
            completionError = $0
        }
        
        // Simulate network response with the error
        let networkError = TestError()
        env.messageUpdater.loadReplies_completion?(networkError)
        
        // Assert error is propagated
        AssertAsync.willBeEqual(completionError as? TestError, networkError)
    }
    
    func test_loadPreviousReplies_propagatesNilError() {
        // Simulate `loadPreviousReplies` call and catch the completion
        var completionCalled = false
        controller.loadPreviousReplies { [callbackQueueID] in
            AssertTestQueue(withId: callbackQueueID)
            XCTAssertNil($0)
            completionCalled = true
        }
        
        // Simulate successful network response
        env.messageUpdater.loadReplies_completion?(nil)
        
        // Assert completion is called
        AssertAsync.willBeTrue(completionCalled)
    }
    
    func test_loadPreviousReplies_callsMessageUpdater_withCorrectValues() {
        // Simulate `loadNextReplies` call
        controller.loadPreviousReplies()
        
        // Assert message updater is called with correct values
        XCTAssertEqual(env.messageUpdater.loadReplies_cid, controller.cid)
        XCTAssertEqual(env.messageUpdater.loadReplies_messageId, messageId)
        XCTAssertEqual(env.messageUpdater.loadReplies_pagination, .init(pageSize: 25))
    }
    
    func test_loadNextReplies_failsOnEmptyReplies() throws {
        // Simulate `loadNextReplies` call and catch the completion error.
        let completionError = try await {
            controller.loadNextReplies(completion: $0)
        }
        
        // Assert correct error is thrown
        AssertAsync.willBeTrue(completionError is ClientError.MessageEmptyReplies)
    }
    
    func test_loadNextReplies_propagatesError() {
        // Simulate `loadNextReplies` call and catch the completion
        var completionError: Error?
        controller.loadNextReplies(after: .unique) { [callbackQueueID] in
            AssertTestQueue(withId: callbackQueueID)
            completionError = $0
        }
        
        // Simulate network response with the error
        let networkError = TestError()
        env.messageUpdater.loadReplies_completion?(networkError)
        
        // Assert error is propagated
        AssertAsync.willBeEqual(completionError as? TestError, networkError)
    }
    
    func test_loadNextReplies_propagatesNilError() {
        // Simulate `loadNextReplies` call and catch the completion
        var completionCalled = false
        controller.loadNextReplies(after: .unique) { [callbackQueueID] in
            AssertTestQueue(withId: callbackQueueID)
            XCTAssertNil($0)
            completionCalled = true
        }
        
        // Simulate successful network response
        env.messageUpdater.loadReplies_completion?(nil)
        
        // Assert completion is called
        AssertAsync.willBeTrue(completionCalled)
    }
    
    func test_loadNextReplies_callsMessageUpdater_withCorrectValues() {
        // Simulate `loadNextReplies` call
        let afterMessageId: MessageId = .unique
        controller.loadNextReplies(after: afterMessageId)
        
        // Assert message updater is called with correct values
        XCTAssertEqual(env.messageUpdater.loadReplies_cid, controller.cid)
        XCTAssertEqual(env.messageUpdater.loadReplies_messageId, messageId)
        XCTAssertEqual(env.messageUpdater.loadReplies_pagination, .init(pageSize: 25, parameter: .greaterThan(afterMessageId)))
    }
}

private class TestDelegate: QueueAwareDelegate, ChatMessageControllerDelegate {
    @Atomic var state: DataController.State?
    @Atomic var didChangeMessage_change: EntityChange<ChatMessage>?
    @Atomic var didChangeReplies_changes: [ListChange<ChatMessage>] = []
    
    func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state = state
        validateQueue()
    }
    
    func messageController(_ controller: ChatMessageController, didChangeMessage change: EntityChange<ChatMessage>) {
        didChangeMessage_change = change
        validateQueue()
    }
    
    func messageController(_ controller: ChatMessageController, didChangeReplies changes: [ListChange<ChatMessage>]) {
        didChangeReplies_changes = changes
        validateQueue()
    }
}

private class TestDelegateGeneric: QueueAwareDelegate, _MessageControllerDelegate {
    @Atomic var state: DataController.State?
    @Atomic var didChangeMessage_change: EntityChange<ChatMessage>?
   
    func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state = state
        validateQueue()
    }
    
    func messageController(_ controller: ChatMessageController, didChangeMessage change: EntityChange<ChatMessage>) {
        didChangeMessage_change = change
        validateQueue()
    }
}

private class TestEnvironment {
    var messageUpdater: MessageUpdaterMock<DefaultExtraData>!
    var messageObserver: EntityDatabaseObserverMock<_ChatMessage<DefaultExtraData>, MessageDTO>!
    var messageObserver_synchronizeError: Error?
    
    lazy var controllerEnvironment: ChatMessageController
        .Environment = .init(
            messageObserverBuilder: { [unowned self] in
                self.messageObserver = .init(context: $0, fetchRequest: $1, itemCreator: $2, fetchedResultsControllerType: $3)
                self.messageObserver.synchronizeError = self.messageObserver_synchronizeError
                return self.messageObserver!
            },
            messageUpdaterBuilder: { [unowned self] in
                self.messageUpdater = MessageUpdaterMock(database: $0, webSocketClient: $1, apiClient: $2)
                return self.messageUpdater!
            }
        )
}