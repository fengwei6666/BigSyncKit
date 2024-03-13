//
//  CloudKitSynchronizer+Sync.swift
//  Pods
//
//  Created by Manuel Entrena on 17/04/2019.
//

import Foundation
import CloudKit

extension CloudKitSynchronizer {
    @MainActor
    func performSynchronization() async {
//        dispatchQueue.async {
//            autoreleasepool {
                self.postNotification(.SynchronizerWillSynchronize)
                self.serverChangeToken = self.storedDatabaseToken
                self.uploadRetries = 0
                self.didNotifyUpload = Set<CKRecordZone.ID>()
                
                self.modelAdapters.forEach {
                    $0.prepareToImport()
                }
                
                await fetchChanges()
    }
    
    @MainActor
    func finishSynchronization(error: Error?) async {
        //        Task { @MainActor in
        resetActiveTokens()
        
        uploadRetries = 0
        
        for adapter in modelAdapters {
            await adapter.didFinishImport(with: error)
        }
        
        //        DispatchQueue(label: "BigSyncKit").async {
        //            autoreleasepool {
        syncing = false
        cancelSync = false
        completion?(error)
        completion = nil
        
        if let error = error {
            self.postNotification(.SynchronizerDidFailToSynchronize, userInfo: [CloudKitSynchronizer.errorKey: error])
            self.delegate?.synchronizerDidfailToSync(self, error: error)
            
            if let error = error as? CKError {
                switch error.code {
                case .changeTokenExpired:
                    // See: https://github.com/mentrena/SyncKit/issues/92#issuecomment-541362433
                    self.resetDatabaseToken()
                    for adapter in self.modelAdapters {
                        await adapter.deleteChangeTracking()
                        self.removeModelAdapter(adapter)
                    }
                    await fetchChanges()
                default:
                    break
                }
            }
        } else {
            postNotification(.SynchronizerDidSynchronize)
            delegate?.synchronizerDidSync(self)
        }
        
        //            debugPrint("QSCloudKitSynchronizer >> Finishing synchronization")
    }
}

// MARK: - Utilities

extension CloudKitSynchronizer {
    func postNotification(_ notification: Notification.Name, object: Any? = nil, userInfo: [AnyHashable: Any]? = nil) {
        let object = object ?? self
        Task { @MainActor in
            NotificationCenter.default.post(name: notification, object: object, userInfo: userInfo)
        }
    }
    
    func runOperation(_ operation: CloudKitSynchronizerOperation) {
        operation.errorHandler = { [weak self] operation, error in
            Task { [weak self] in
                await self?.finishSynchronization(error: error)
            }
        }
        currentOperation = operation
        operationQueue.addOperation(operation)
    }
    
    @MainActor
    func notifyProviderForDeletedZoneIDs(_ zoneIDs: [CKRecordZone.ID]) async {
        for zoneID in zoneIDs {
            await self.adapterProvider.cloudKitSynchronizer(self, zoneWasDeletedWithZoneID: zoneID)
            self.delegate?.synchronizer(self, zoneIDWasDeleted: zoneID)
        }
    }
    
    func loadTokens(for zoneIDs: [CKRecordZone.ID], loadAdapters: Bool) -> [CKRecordZone.ID] {
        var filteredZoneIDs = [CKRecordZone.ID]()
        activeZoneTokens = [CKRecordZone.ID: CKServerChangeToken]()
        
        for zoneID in zoneIDs {
            var modelAdapter = modelAdapterDictionary[zoneID]
            if modelAdapter == nil && loadAdapters {
                if let newModelAdapter = adapterProvider.cloudKitSynchronizer(self, modelAdapterForRecordZoneID: zoneID) {
                    modelAdapter = newModelAdapter
                    modelAdapterDictionary[zoneID] = newModelAdapter
                    delegate?.synchronizer(self, didAddAdapter: newModelAdapter, forRecordZoneID: zoneID)
                    newModelAdapter.prepareToImport()
                }
            }
            
            if let adapter = modelAdapter {
                filteredZoneIDs.append(zoneID)
                activeZoneTokens[zoneID] = adapter.serverChangeToken
            }
        }
        
        return filteredZoneIDs
    }
    
    func resetActiveTokens() {
        activeZoneTokens = [CKRecordZone.ID: CKServerChangeToken]()
    }
    
    func shouldRetryUpload(for error: NSError) -> Bool {
        if isServerRecordChangedError(error) || isLimitExceededError(error) {
            return uploadRetries < 2
        } else {
            return false
        }
    }
    
    func isServerRecordChangedError(_ error: NSError) -> Bool {
        
        if error.code == CKError.partialFailure.rawValue,
            let errorsByItemID = error.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: NSError],
            errorsByItemID.values.contains(where: { (error) -> Bool in
                return error.code == CKError.serverRecordChanged.rawValue
            }) {
            
            return true
        }
        
        return error.code == CKError.serverRecordChanged.rawValue
    }
    
    func isZoneNotFoundOrDeletedError(_ error: Error?) -> Bool {
        if let error = error {
            let nserror = error as NSError
            return nserror.code == CKError.zoneNotFound.rawValue || nserror.code == CKError.userDeletedZone.rawValue
        } else {
            return false
        }
    }
    
    func isLimitExceededError(_ error: NSError) -> Bool {
        if error.code == CKError.partialFailure.rawValue,
            let errorsByItemID = error.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: NSError],
            errorsByItemID.values.contains(where: { (error) -> Bool in
                return error.code == CKError.limitExceeded.rawValue
            }) {
            
            return true
        }
        
        return error.code == CKError.limitExceeded.rawValue
    }
    
    func sequential<T>(objects: [T], closure: @escaping (T, @escaping (Error?) async -> ()) async -> (), final: @escaping (Error?) async -> ()) async {
        guard let first = objects.first else {
            await final(nil)
            return
        }
        
        await closure(first) { [weak self] error in
            guard error == nil else {
                await final(error)
                return
            }
            
            var remaining = objects
            remaining.removeFirst()
            await self?.sequential(objects: remaining, closure: closure, final: final)
        }
    }
    
    func needsZoneSetup(adapter: ModelAdapter) -> Bool {
        return adapter.serverChangeToken == nil
    }
}

//MARK: - Fetch changes

extension CloudKitSynchronizer {
    @MainActor
    func fetchChanges() async {
        guard cancelSync == false else {
            await finishSynchronization(error: SyncError.cancelled)
            return
        }
        
        postNotification(.SynchronizerWillFetchChanges)
        
//        print("!! fetch DB changes")
        await fetchDatabaseChanges() { [weak self] token, error in
//        print("!! fetch DB changes: FINISHED")
            guard let self = self else { return }
            guard error == nil else {
                await finishSynchronization(error: error)
                return
            }
            
            serverChangeToken = token
            storedDatabaseToken = token
            if syncMode == .sync {
                await uploadChanges()
            } else {
                await finishSynchronization(error: nil)
            }
        }
    }
    
    @BigSyncActor
    func fetchDatabaseChanges(completion: @escaping (CKServerChangeToken?, Error?) async -> ()) async {
        let operation = await FetchDatabaseChangesOperation(database: database, databaseToken: serverChangeToken) { (token, changedZoneIDs, deletedZoneIDs) in
            Task.detached(priority: .background) { @BigSyncActor [weak self] in
                guard let self = self else { return }
                await notifyProviderForDeletedZoneIDs(deletedZoneIDs)
                
                let zoneIDsToFetch = await loadTokens(for: changedZoneIDs, loadAdapters: true)
                
                guard zoneIDsToFetch.count > 0 else {
                    await self.resetActiveTokens()
                    await completion(token, nil)
                    return
                }
                
                await Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    zoneIDsToFetch.forEach {
                        self.delegate?.synchronizerWillFetchChanges(self, in: $0)
                    }
                    
                    fetchZoneChanges(zoneIDsToFetch) { [weak self] error in
                        guard let self = self else { return }
                        guard error == nil else {
                            await finishSynchronization(error: error)
                            return
                        }
                        
                        await mergeChanges() { error in
                            await completion(token, error)
                        }
                    }
                }.value
            }
        }
        
        await runOperation(operation)
    }
    
    @MainActor
    func fetchZoneChanges(_ zoneIDs: [CKRecordZone.ID], completion: @escaping (Error?) async -> ()) {
        let operation = FetchZoneChangesOperation(database: database, zoneIDs: zoneIDs, zoneChangeTokens: activeZoneTokens, modelVersion: compatibilityVersion, ignoreDeviceIdentifier: deviceIdentifier, desiredKeys: nil) { (zoneResults) in
            
            //            self.dispatchQueue.async {
            await Task.detached(priority: .background) { [weak self] in
                guard let self = self else { return }
                var pendingZones = [CKRecordZone.ID]()
                var error: Error? = nil
                
                for (zoneID, result) in zoneResults {
                    let adapter = await modelAdapterDictionary[zoneID]
                    if let resultError = result.error {
                        if await isZoneNotFoundOrDeletedError(error) {
                            await notifyProviderForDeletedZoneIDs([zoneID])
                        } else {
                            error = resultError
                            break
                        }
                    } else {
                        if !result.downloadedRecords.isEmpty {
                            debugPrint("QSCloudKitSynchronizer >> Downloaded \(result.downloadedRecords.count) changed records >> from zone \(zoneID.zoneName)")
                            debugPrint("QSCloudKitSynchronizer >> Downloads: \(result.downloadedRecords.map { ($0.recordType, $0.recordID.recordName, $0.creationDate) })")
                        }
                        if !result.deletedRecordIDs.isEmpty {
                            debugPrint("QSCloudKitSynchronizer >> Downloaded \(result.deletedRecordIDs.count) deleted record IDs >> from zone \(zoneID.zoneName)")
                        }
                        await Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            activeZoneTokens[zoneID] = result.serverChangeToken
                            await adapter?.saveChanges(in: result.downloadedRecords)
                            await adapter?.deleteRecords(with: result.deletedRecordIDs)
                        }.value
                        if result.moreComing {
                            pendingZones.append(zoneID)
                        }
                    }
                }
                
                if pendingZones.count > 0 && error == nil {
                    let zones = pendingZones
                    //                    Task { @MainActor in
                    await fetchZoneChanges(zones, completion: completion)
                    //                    }
                } else {
                    //                    Task { @MainActor in
                    await completion(error)
                    //                    }
                    //                }
                }
            }.value
        }
        
        runOperation(operation)
    }
    
    @MainActor
    func mergeChanges(completion: @escaping (Error?) async -> ()) async {
        guard cancelSync == false else {
            await finishSynchronization(error: SyncError.cancelled)
            return
        }
        
        var adapterSet = [ModelAdapter]()
        activeZoneTokens.keys.forEach {
            if let adapter = self.modelAdapterDictionary[$0] {
                adapterSet.append(adapter)
            }
        }

        await sequential(objects: adapterSet, closure: mergeChangesIntoAdapter, final: completion)
    }
    
    @MainActor
    func mergeChangesIntoAdapter(_ adapter: ModelAdapter, completion: @escaping (Error?) async -> ()) async {
        await adapter.persistImportedChanges { @MainActor [weak self] error in
            //            self.dispatchQueue.async {
            //                autoreleasepool {
            guard let self = self else { return }
            guard error == nil else {
                await completion(error)
                return
            }
            if let token = activeZoneToken(zoneID: adapter.recordZoneID) {
                await adapter.saveToken(token)
            }
            await completion(nil)
        }
    }
}

// MARK: - Upload changes

extension CloudKitSynchronizer {
    @MainActor
    func uploadChanges() async {
        guard cancelSync == false else {
            await finishSynchronization(error: SyncError.cancelled)
            return
        }
        
        postNotification(.SynchronizerWillUploadChanges)
        
        await uploadChanges() { [weak self] (error) in
            guard let self = self else { return }
            if let error = error {
#warning("FIXME: handle zone not found...")
                //                if let error = error as? CKError {
//                    if let errors = error.partialErrorsByItemID {
//                        if errors.contains(where: { ($0.value as? CKError)?.code == .zoneNotFound || ($0.value as? CKError)?.code == .userDeletedZone }) {
//                        }
//                    }
//                    if error.code == .zoneNotFound || error.code == .userDeletedZone ||  {
//                    }
//                }

                if shouldRetryUpload(for: error as NSError) {
                    uploadRetries += 1
//                    Task.detached { [weak self] in
                        await fetchChanges()
//                    }
                } else {
                    await finishSynchronization(error: error)
                }
            } else {
                increaseBatchSize()
                updateTokens()
            }
        }
    }
    
    @MainActor
    func uploadChanges(completion: @escaping (Error?) async -> ()) async {
        await sequential(objects: modelAdapters, closure: setupZoneAndUploadRecords) { [weak self] (error) in
            guard error == nil else { await completion(error); return }
            guard let self = self else { return }
            
            await sequential(objects: modelAdapters, closure: uploadDeletions, final: completion)
        }
    }
    
    @MainActor
    func setupZoneAndUploadRecords(adapter: ModelAdapter, completion: @escaping (Error?) async -> ()) async {
        await setupRecordZoneIfNeeded(adapter: adapter) { [weak self] (error) in
            guard let self = self, error == nil else {
                await completion(error)
                return
            }
            await uploadRecords(adapter: adapter, completion: { (error) in
                await completion(error)
            })
        }
    }
    
    @MainActor
    func setupRecordZoneIfNeeded(adapter: ModelAdapter, completion: @escaping (Error?) async -> ()) async {
        guard needsZoneSetup(adapter: adapter) else {
            await completion(nil)
            return
        }
        
        setupRecordZoneID(adapter.recordZoneID, completion: completion)
    }
    
    @MainActor
    func setupRecordZoneID(_ zoneID: CKRecordZone.ID, completion: @escaping (Error?) async -> ()) {
        database.fetch(withRecordZoneID: zoneID) { [weak self] (zone, error) in
            guard let self = self else { return }
            if isZoneNotFoundOrDeletedError(error) {
                let newZone = CKRecordZone(zoneID: zoneID)
                database.save(zone: newZone, completionHandler: { (zone, error) in
                    if error == nil && zone != nil {
                        debugPrint("QSCloudKitSynchronizer >> Created custom record zone: \(newZone.description)")
                    }
                    Task {
                        await completion(error)
                    }
                })
            } else {
                Task {
                    await completion(error)
                }
            }
        }
    }
    
    func uploadRecords(adapter: ModelAdapter, completion: @escaping (Error?) async -> ()) async {
        let records = adapter.recordsToUpload(limit: batchSize)
        let recordCount = records.count
        let requestedBatchSize = batchSize
        guard recordCount > 0 else { await completion(nil); return }
        
        if !didNotifyUpload.contains(adapter.recordZoneID) {
            didNotifyUpload.insert(adapter.recordZoneID)
            delegate?.synchronizerWillUploadChanges(self, to: adapter.recordZoneID)
        }
        
        //Add metadata: device UUID and model version
        addMetadata(to: records)
        
        let modifyRecordsOperation = ModifyRecordsOperation(database: database,
                                               records: records,
                                               recordIDsToDelete: nil)
        { [weak self] (savedRecords, deleted, conflicted, operationError) in
            Task { [weak self] in
                guard let self = self else { return }
                //            self.dispatchQueue.async {
                //                autoreleasepool {
                if !(savedRecords?.isEmpty ?? true) {
                    debugPrint("QSCloudKitSynchronizer >> Uploaded \(savedRecords?.count ?? 0) records")
                }
                await adapter.didUpload(savedRecords: savedRecords ?? [])
                
                if let error = operationError {
                    if self.isLimitExceededError(error as NSError) {
                        reduceBatchSize()
                        await completion(error)
                    } else if !conflicted.isEmpty {
                        await adapter.saveChanges(in: conflicted)
                        await adapter.persistImportedChanges { (persistError) in
                            await completion(error)
                        }
                    } else {
                        await completion(error)
                    }
                } else {
                    if recordCount >= requestedBatchSize {
                        await uploadRecords(adapter: adapter, completion: completion)
                    } else {
                        await completion(nil)
                    }
                }
                //                }
            }
        }
        
        runOperation(modifyRecordsOperation)
    }
    
    @MainActor
    func uploadDeletions(adapter: ModelAdapter, completion: @escaping (Error?) async -> ()) async {
        let recordIDs = adapter.recordIDsMarkedForDeletion(limit: batchSize)
        let recordCount = recordIDs.count
        let requestedBatchSize = batchSize
        
        guard recordCount > 0 else {
            await completion(nil)
            return
        }
        
        let modifyRecordsOperation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
        modifyRecordsOperation.modifyRecordsCompletionBlock = { savedRecords, deletedRecordIDs, operationError in
//            self.dispatchQueue.async {
//                autoreleasepool {
            Task { [weak self] in
                guard let self = self else { return }
                debugPrint("QSCloudKitSynchronizer >> Deleted \(recordCount) records")
                    await adapter.didDelete(recordIDs: deletedRecordIDs ?? [])
                    
                    if let error = operationError {
                        if isLimitExceededError(error as NSError) {
                            reduceBatchSize()
                        }
                        await completion(error)
                    } else {
                        if recordCount >= requestedBatchSize {
                            await uploadDeletions(adapter: adapter, completion: completion)
                        } else {
                            await completion(nil)
                        }
                    }
//                }
            }
        }
        
        currentOperation = modifyRecordsOperation
        database.add(modifyRecordsOperation)
    }
    
    // MARK: - 
    
    @MainActor
    func updateTokens() {
        let operation = FetchDatabaseChangesOperation(database: database, databaseToken: serverChangeToken) { (databaseToken, changedZoneIDs, deletedZoneIDs) in
            Task { [weak self] in
                guard let self = self else { return }
                //            self.dispatchQueue.async {
                //                autoreleasepool {
                //            Task { @MainActor in
                await notifyProviderForDeletedZoneIDs(deletedZoneIDs)
                if changedZoneIDs.count > 0 {
                    let zoneIDs = loadTokens(for: changedZoneIDs, loadAdapters: false)
                    await updateServerToken(for: zoneIDs, completion: { [weak self] (needsToFetchChanges) in
                        guard let self = self else { return }
                        if needsToFetchChanges {
                            await performSynchronization()
                        } else {
                            storedDatabaseToken = databaseToken
                            await finishSynchronization(error: nil)
                        }
                    })
                } else {
                    await finishSynchronization(error: nil)
                }
            }
        }
        runOperation(operation)
    }
    
    @MainActor
    func updateServerToken(for recordZoneIDs: [CKRecordZone.ID], completion: @escaping (Bool) async -> ()) async {
        // If we found a new record zone at this point then needsToFetchChanges=true
        var hasAllTokens = true
        for zoneID in recordZoneIDs {
            if activeZoneTokens[zoneID] == nil {
                hasAllTokens = false
            }
        }
        guard hasAllTokens else {
            await completion(true)
            return
        }
        
        let operation = FetchZoneChangesOperation(database: database, zoneIDs: recordZoneIDs, zoneChangeTokens: activeZoneTokens, modelVersion: compatibilityVersion, ignoreDeviceIdentifier: deviceIdentifier, desiredKeys: ["recordID", CloudKitSynchronizer.deviceUUIDKey]) { @MainActor [weak self] zoneResults in
            //            self.dispatchQueue.async {
            //                autoreleasepool {
            guard let self = self else { return }
            var pendingZones = [CKRecordZone.ID]()
            var needsToRefetch = false
            
            for (zoneID, result) in zoneResults {
                let adapter = modelAdapterDictionary[zoneID]
                if result.downloadedRecords.count > 0 || result.deletedRecordIDs.count > 0 {
                    needsToRefetch = true
                } else {
                    activeZoneTokens[zoneID] = result.serverChangeToken
                    await adapter?.saveToken(result.serverChangeToken)
                }
                if result.moreComing {
                    pendingZones.append(zoneID)
                }
            }
            
            if pendingZones.count > 0 && !needsToRefetch {
                await updateServerToken(for: pendingZones, completion: completion)
            } else {
                await completion(needsToRefetch)
            }
        }
        runOperation(operation)
    }
    
    func reduceBatchSize() {
        self.batchSize = self.batchSize / 2
    }
    
    func increaseBatchSize() {
        if self.batchSize < CloudKitSynchronizer.defaultBatchSize {
            self.batchSize = self.batchSize + 5
        }
    }
}
