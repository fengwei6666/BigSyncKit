//
//  CloudKitSynchronizer.swift
//  Pods
//
//  Created by Manuel Entrena on 05/04/2019.
//

import Foundation
import CloudKit

// For Swift
public extension Notification.Name {
    
    /// Sent when the synchronizer is going to start a sync with CloudKit.
    static let SynchronizerWillSynchronize = Notification.Name("QSCloudKitSynchronizerWillSynchronizeNotification")
    /// Sent when the synchronizer is going to start the fetch stage, where it downloads any new changes from CloudKit.
    static let SynchronizerWillFetchChanges = Notification.Name("QSCloudKitSynchronizerWillFetchChangesNotification")
    /// Sent when the synchronizer is going to start the upload stage, where it sends changes to CloudKit.
    static let SynchronizerWillUploadChanges = Notification.Name("QSCloudKitSynchronizerWillUploadChangesNotification")
    /// Sent when the synchronizer finishes syncing.
    static let SynchronizerDidSynchronize = Notification.Name("QSCloudKitSynchronizerDidSynchronizeNotification")
    /// Sent when the synchronizer encounters an error while syncing.
    static let SynchronizerDidFailToSynchronize = Notification.Name("QSCloudKitSynchronizerDidFailToSynchronizeNotification")
    
    static let SynchronizerDidFetchRecord = Notification.Name("QSCloudKitSynchronizerDidFetchRecordNotification")
}

// For Obj-C
@objc public extension NSNotification {
    /// Sent when the synchronizer is going to start a sync with CloudKit.
    static let CloudKitSynchronizerWillSynchronizeNotification: NSString = "QSCloudKitSynchronizerWillSynchronizeNotification"
    /// Sent when the synchronizer is going to start the fetch stage, where it downloads any new changes from CloudKit.
    static let CloudKitSynchronizerWillFetchChangesNotification: NSString = "QSCloudKitSynchronizerWillFetchChangesNotification"
    /// Sent when the synchronizer is going to start the upload stage, where it sends changes to CloudKit.
    static let CloudKitSynchronizerWillUploadChangesNotification: NSString = "QSCloudKitSynchronizerWillUploadChangesNotification"
    /// Sent when the synchronizer finishes syncing.
    static let CloudKitSynchronizerDidSynchronizeNotification: NSString = "QSCloudKitSynchronizerDidSynchronizeNotification"
    /// Sent when the synchronizer encounters an error while syncing.
    static let CloudKitSynchronizerDidFailToSynchronizeNotification: NSString = "QSCloudKitSynchronizerDidFailToSynchronizeNotification"
}

/// An `AdapterProvider` gets requested for new model adapters when a `CloudKitSynchronizer` encounters a new `CKRecordZone` that does not already correspond to an existing model adapter.
//@objc public protocol AdapterProvider {
public protocol AdapterProvider {

    /// The `CloudKitSynchronizer` requests a new model adapter for the given record zone.
    /// - Parameters:
    ///   - synchronizer: `QSCloudKitSynchronizer` asking for the adapter.
    ///   - zoneID: `CKRecordZoneID` that the model adapter will be used for.
    /// - Returns: `ModelAdapter` correctly configured to sync changes in the given record zone.
    func cloudKitSynchronizer(_ synchronizer: CloudKitSynchronizer, modelAdapterForRecordZoneID zoneID: CKRecordZone.ID) -> ModelAdapter?

    /// The `CloudKitSynchronizer` informs the provider that a record zone was deleted so it can clean up any associated data.
    /// - Parameters:
    ///   - synchronizer: `QSCloudKitSynchronizer` that found the deleted record zone.
    ///   - zoneID: `CKRecordZoneID` of the record zone that was deleted.
    func cloudKitSynchronizer(_ synchronizer: CloudKitSynchronizer, zoneWasDeletedWithZoneID zoneID: CKRecordZone.ID) async
}

//@objc public protocol CloudKitSynchronizerDelegate: AnyObject {
public protocol CloudKitSynchronizerDelegate: AnyObject {
    func synchronizerWillFetchChanges(_ synchronizer: CloudKitSynchronizer, in recordZone: CKRecordZone.ID)
    func synchronizerWillUploadChanges(_ synchronizer: CloudKitSynchronizer, to recordZone: CKRecordZone.ID)
    func synchronizerDidSync(_ synchronizer: CloudKitSynchronizer)
    func synchronizerDidfailToSync(_ synchronizer: CloudKitSynchronizer, error: Error)
    func synchronizer(_ synchronizer: CloudKitSynchronizer, didAddAdapter adapter: ModelAdapter, forRecordZoneID zoneID: CKRecordZone.ID)
    func synchronizer(_ synchronizer: CloudKitSynchronizer, zoneIDWasDeleted zoneID: CKRecordZone.ID)
}

/**
 A `CloudKitSynchronizer` object takes care of making all the required calls to CloudKit to keep your model synchronized, using the provided
 `ModelAdapter` to interact with it.
 
 `CloudKitSynchronizer` will post notifications at different steps of the synchronization process.
 */
public class CloudKitSynchronizer: NSObject {
    /// SyncError
    public enum SyncError: Int, Error {
        /**
         *  Received when synchronize is called while there was an ongoing synchronization.
         */
        case alreadySyncing = 0
        /**
         *  A synchronizer with a higer `compatibilityVersion` value uploaded changes to CloudKit, so those changes won't be imported here.
         *  This error can be detected to prompt the user to update the app to a newer version.
         */
        case higherModelVersionFound = 1
        /**
         *  A record fot the provided object was not found, so the object cannot be shared on CloudKit.
         */
        case recordNotFound = 2
        /**
         *  Synchronization was manually cancelled.
         */
        case cancelled = 3
        
        case notAllow = 4
    }
    
    /// `CloudKitSynchronizer` can be configured to only download changes, never uploading local changes to CloudKit.
    public enum SynchronizeMode: Int {
        /// Download and upload all changes
        case sync
        /// Only download changes
        case downloadOnly
    }
    
    public static let errorDomain = "CloudKitSynchronizerErrorDomain"
    public static let errorKey = "CloudKitSynchronizerErrorKey"
    
    /**
     More than one `CloudKitSynchronizer` may be created in an app.
     The identifier is used to persist some state, so it should always be the same for a synchronizer –if you change your app to use a different identifier state might be lost.
     */
    public let identifier: String
    
    /// iCloud container identifier.
    public let containerIdentifier: String?
    
    public var container: CKContainer?
    
    /// Adapter wrapping a `CKDatabase`. The synchronizer will run CloudKit operations on the given database.
    @BigSyncBackgroundActor
    public let database: CloudKitDatabaseAdapter
    
    /// Provides the model adapter to the synchronizer.
    @BigSyncBackgroundActor
    public let adapterProvider: AdapterProvider
    
    /// Required by the synchronizer to persist some state. `UserDefaults` can be used via `UserDefaultsAdapter`.
    @BigSyncBackgroundActor
    public let keyValueStore: KeyValueStore
    
    /// Indicates whether the instance is currently synchronizing data.
    public internal(set) var syncing: Bool = false
    
    public var allowSyncing: Bool = true
    
    ///  Number of records that are sent in an upload operation.
    public var batchSize: Int = CloudKitSynchronizer.defaultBatchSize
    
    /**
    *  When set, if the synchronizer finds records uploaded by a different device using a higher compatibility version,
    *   it will end synchronization with a `higherModelVersionFound` error.
    */
    public var compatibilityVersion: Int = 0
    
    /// Whether the synchronizer will only download data or also upload any local changes.
    public var syncMode: SynchronizeMode = .sync
    
    @BigSyncBackgroundActor
    public var delegate: CloudKitSynchronizerDelegate?
    
//    internal let dispatchQueue = DispatchQueue(label: "QSCloudKitSynchronizer")
    @BigSyncBackgroundActor
    internal let operationQueue = OperationQueue()
    internal var modelAdapterDictionary = [CKRecordZone.ID: ModelAdapter]()
    internal var serverChangeToken: CKServerChangeToken?
    internal var activeZoneTokens = [CKRecordZone.ID: CKServerChangeToken]()
    internal var cancelSync = false
    internal var completion: ((Error?) -> ())?
    @BigSyncBackgroundActor
    internal weak var currentOperation: Operation?
    internal var uploadRetries = 0
    internal var didNotifyUpload = Set<CKRecordZone.ID>()
    
    /// Default number of records to send in an upload operation.
    public static var defaultBatchSize = 400 // Apple's suggestion
    static let deviceUUIDKey = "QSCloudKitDeviceUUIDKey"
    static let modelCompatibilityVersionKey = "QSCloudKitModelCompatibilityVersionKey"
    
    /// Initializes a newly allocated synchronizer.
    /// - Parameters:
    ///   - identifier: Identifier for the `QSCloudKitSynchronizer`.
    ///   - containerIdentifier: Identifier of the iCloud container to be used. The application must have the right entitlements to be able to access this container.
    ///   - database: Private or Shared CloudKit Database
    ///   - adapterProvider: `CloudKitSynchronizerAdapterProvider`
    ///   - keyValueStore: Object conforming to KeyValueStore (`UserDefaultsAdapter`, for example)
    /// - Returns: Initialized synchronizer or `nil` if no iCloud container can be found with the provided identifier.
    public init(
        identifier: String,
        containerIdentifier: String? = nil,
        database: CloudKitDatabaseAdapter,
        adapterProvider: AdapterProvider,
        keyValueStore: KeyValueStore = UserDefaultsAdapter(userDefaults: UserDefaults.standard),
        compatibilityVersion: Int = 0
    ) {
        self.identifier = identifier
        self.containerIdentifier = containerIdentifier
        self.adapterProvider = adapterProvider
        self.database = database
        self.keyValueStore = keyValueStore
        self.compatibilityVersion = compatibilityVersion
        super.init()
        
        BackupDetection.runBackupDetection { (result, error) in
            if result == .restoredFromBackup {
                self.clearDeviceIdentifier()
            }
        }
    }
    
    fileprivate var _deviceIdentifier: String!
    var deviceIdentifier: String {
        if _deviceIdentifier == nil {
            _deviceIdentifier = deviceUUID
            if _deviceIdentifier == nil {
                _deviceIdentifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
                deviceUUID = _deviceIdentifier
            }
        }
        return _deviceIdentifier
    }
    
    public var forceSaveRecordOnce = false
    
    internal func clearDeviceIdentifier() {
        deviceUUID = nil
    }
    
    @BigSyncBackgroundActor
    public func resetSyncCaches(includingAdapters: Bool = true) async throws {
        cancelSynchronization()
        
        clearDeviceIdentifier()
        resetDatabaseToken()
        resetActiveTokens()
        
        if includingAdapters {
            for adapter in modelAdapters {
                try await adapter.resetSyncCaches()
            }
        }
        forceSaveRecordOnce = true
    }
    
    // MARK: - Public
    
    ///  These keys will be added to CKRecords uploaded to CloudKit and are used by SyncKit internally.
    public static let metadataKeys: [String] = [CloudKitSynchronizer.deviceUUIDKey, CloudKitSynchronizer.modelCompatibilityVersionKey]
    
    /// Synchronize data with CloudKit.
    /// - Parameter completion: Completion block that receives an optional error. Could be a `SyncError`, `CKError`, or any other error found during synchronization.
    @BigSyncBackgroundActor
    @objc public func synchronize(completion: ((Error?) -> ())?) {
        guard allowSyncing else {
            completion?(SyncError.notAllow)
            return
        }
        
        guard !syncing else {
            completion?(SyncError.alreadySyncing)
            return
        }
        
//        debugPrint("CloudKitSynchronizer >> Initiating synchronization", identifier, containerIdentifier)
        cancelSync = false
        syncing = true
        self.completion = completion
        
        Task(priority: .background) { @BigSyncBackgroundActor [weak self] in
            await self?.performSynchronization()
        }
    }
    
    /// Cancel synchronization. It will cause a current synchronization to end with a `cancelled` error.
    @BigSyncBackgroundActor
    @objc public func cancelSynchronization() {
        guard syncing, !cancelSync else { return }
        
        cancelSync = true
        currentOperation?.cancel()
    }
    
    /**
    *  Deletes saved database token, so next synchronization will include changes in all record zones in the database.
    * This does not reset tokens stored by model adapters.
    */
    @objc public func resetDatabaseToken() {
        storedDatabaseToken = nil
    }
    
    internal func activeZoneToken(zoneID: CKRecordZone.ID) -> CKServerChangeToken? {
        return activeZoneTokens[zoneID]
    }
    
//    /**
//    * Deletes saved database token and all local metadata used to track changes in models.
//    * The synchronizer should not be used after calling this function, create a new synchronizer instead if you need it.
//    */
//    @BigSyncBackgroundActor
//    @objc public func eraseLocalMetadata(removeModelAdapters: Bool) {
//        cancelSynchronization()
//        
////        dispatchQueue.async {
//        Task(priority: .background) { @BigSyncBackgroundActor [weak self] in
//            guard let self = self else { return }
//            storedDatabaseToken = nil
//            clearAllStoredSubscriptionIDs()
//            deviceUUID = nil
//            for modelAdapter in modelAdapters {
//                await modelAdapter.deleteChangeTracking()
//                if removeModelAdapters {
//                    removeModelAdapter(modelAdapter)
////                } else {
////                    await modelAdapter.saveToken(nil)
//                }
//            }
//        }
//    }
    
    /// Deletes the corresponding record zone on CloudKit, along with any data in it.
    /// - Parameters:
    ///   - adapter: Model adapter whose corresponding record zone should be deleted
    ///   - completion: Completion block.
    @BigSyncBackgroundActor
    public func deleteRecordZone(for adapter: ModelAdapter, completion: ((Error?) -> ())?) {
        database.delete(withRecordZoneID: adapter.recordZoneID) { (zoneID, error) in
            Task(priority: .background) { @BigSyncBackgroundActor in
                await adapter.saveToken(nil)
                if let error = error {
                    debugPrint("CloudKitSynchronizer >> Error: \(error)")
                } else {
                    debugPrint("CloudKitSynchronizer >> Deleted zone: \(zoneID?.debugDescription ?? "")")
                }
                completion?(error)
            }
        }
    }
    
    /// Model adapters in use by this synchronizer
    public var modelAdapters: [ModelAdapter] {
        return Array(modelAdapterDictionary.values)
    }
    
    /// Adds a new model adapter to be synchronized with CloudKit.
    /// - Parameter adapter: The adapter to be managed by this synchronizer.
    public func addModelAdapter(_ adapter: ModelAdapter) {
        modelAdapterDictionary[adapter.recordZoneID] = adapter
        adapter.initialSetupDelegate = self
    }
    
    /// Removes the model adapter so data managed by it won't be synced with CloudKit any more.
    /// - Parameter adapter: Adapter to be removed from the synchronizer
    public func removeModelAdapter(_ adapter: ModelAdapter) {
        modelAdapterDictionary.removeValue(forKey: adapter.recordZoneID)
    }
}

extension CloudKitSynchronizer: RealmSwiftAdapterInitialSetupDelegate {
    public func needsInitialSetup() async throws {
        try await resetSyncCaches(includingAdapters: false)
    }
}
