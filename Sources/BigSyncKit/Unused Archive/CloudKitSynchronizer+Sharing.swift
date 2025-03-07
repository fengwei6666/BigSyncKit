////
////  CloudKitSynchronizer+Sharing.swift
////  Pods
////
////  Created by Manuel Entrena on 07/04/2019.
////
//
//import Foundation
//import CloudKit
//
//@objc public extension CloudKitSynchronizer {
//    
//    fileprivate func modelAdapter(for object: AnyObject) -> ModelAdapter? {
//        for modelAdapter in modelAdapters {
//            if modelAdapter.record(for: object) != nil {
//                return modelAdapter
//            }
//        }
//        return nil
//    }
//    
//    /**
//     Returns the locally stored `CKShare` for a given model object.
//     - Parameter object  The model object.
//     - Returns: `CKShare` stored for the given object.
//     */
//    @objc func share(for object: AnyObject) -> CKShare? {
//        guard let modelAdapter = modelAdapter(for: object) else {
//            return nil
//        }
//        return modelAdapter.share(for: object)
//    }
//    
//    /**
//     Saves the given `CKShare` locally for the given model object.
//     - Parameters:
//        - share The `CKShare`.
//        - object  The model object.
//     
//        This method should be called by your `UICloudSharingControllerDelegate`, when `cloudSharingControllerDidSaveShare` is called.
//     */
//    @objc func cloudSharingControllerDidSaveShare(_ share: CKShare, for object: AnyObject) {
//        guard let modelAdapter = modelAdapter(for: object) else {
//            return
//        }
//        modelAdapter.save(share: share, for: object)
//    }
//    
//    /**
//     Deletes any `CKShare` locally stored  for the given model object.
//     - Parameters:
//        - object  The model object.
//     This method should be called by your `UICloudSharingControllerDelegate`, when `cloudSharingControllerDidStopSharing` is called.
//     */
//    @objc func cloudSharingControllerDidStopSharing(for object: AnyObject) {
//        guard let modelAdapter = modelAdapter(for: object) else {
//            return
//        }
//        
//        modelAdapter.deleteShare(for: object)
//        
//        /**
//         There is a bug on CloudKit. The record that was shared will be changed as a result of its share being deleted.
//         However, this change is not returned by CloudKit on the next CKFetchZoneChangesOperation, so our local record
//         becomes out of sync. To avoid that, we will fetch it here and update our local copy.
//         */
//        
//        guard let record = modelAdapter.record(for: object) else {
//            return
//        }
//
//        database.fetch(withRecordID: record.recordID) { (updated, error) in
//            if let updated = updated {
//                modelAdapter.saveChanges(in: [updated])
//                modelAdapter.persistImportedChanges { (error) in
//                    modelAdapter.didFinishImport(with: error)
//                }
//            }
//        }
//    }
//    
//    /**
//     Returns a  `CKShare` for the given model object. If one does not exist, it creates and uploads a new
//     - Parameters:
//        - object The model object to share.
//        - publicPermission  The permissions to be used for the new share.
//        - participants: The participants to add to this share.
//        - completion: Closure that gets called with an optional error when the operation is completed.
//     
//     */
//    @objc func share(object: AnyObject, publicPermission: CKShare.Participant.Permission, participants: [CKShare.Participant], completion: ((CKShare?, Error?) -> ())?) {
//        
//        guard !syncing else {
//            completion?(nil, CloudKitSynchronizer.SyncError.alreadySyncing)
//            return
//        }
//        
//        guard let modelAdapter = modelAdapter(for: object),
//            let record = modelAdapter.record(for: object) else {
//                completion?(nil, CloudKitSynchronizer.SyncError.recordNotFound)
//                return
//        }
//        
//        if let share = modelAdapter.share(for: object) {
//            completion?(share, nil)
//            return
//        }
//        
//        syncing = true
//        
//        let share = CKShare(rootRecord: record)
//        share.publicPermission = publicPermission
//        for participant in participants {
//            share.addParticipant(participant)
//        }
//        
//        addMetadata(to: [record, share])
//        
//        let operation = ModifyRecordsOperation(database: database, records: [record, share], recordIDsToDelete: nil) { (savedRecords, deleted, conflicted, operationError) in
//            //            self.dispatchQueue.async {
//            
//            let uploadedShare = savedRecords?.first { $0 is CKShare} as? CKShare
//            
//            if let savedRecords = savedRecords,
//               operationError == nil,
//               let share = uploadedShare {
//                
//                let records = savedRecords.filter { $0 != share }
//                modelAdapter.didUpload(savedRecords: records)
//                modelAdapter.persistImportedChanges(completion: { (error) in
//                    
//                    //                        self.dispatchQueue.async {
//                    
//                    if error == nil {
//                        modelAdapter.save(share: share, for: object)
//                    }
//                    modelAdapter.didFinishImport(with: error)
//                    
//                    //                    DispatchQueue.main.async {
//                        self.syncing = false
//                        completion?(uploadedShare, error)
////                    }
//                    //                        }
//                })
//                
//            } else if let error = operationError {
//                if self.isServerRecordChangedError(error as NSError),
//                   !conflicted.isEmpty {
//                    modelAdapter.saveChanges(in: conflicted)
//                    modelAdapter.persistImportedChanges { (error) in
//                        modelAdapter.didFinishImport(with: error)
//                        //                        DispatchQueue.main.async {
//                        self.syncing = false
//                        self.share(object: object, publicPermission: publicPermission, participants: participants, completion: completion)
//                        //                        }
//                    }
//                } else {
//                    //                    DispatchQueue.main.async {
//                    self.syncing = false
//                    completion?(uploadedShare, operationError)
//                    //                    }
//                }
//            } else {
//                //                DispatchQueue.main.async {
//                self.syncing = false
//                completion?(nil, operationError)
//                //                }
//            }
//            //            }
//        }
//        runOperation(operation)
//    }
//    
//    /**
//     Removes the existing `CKShare` for an object and deletes it from CloudKit.
//     - Parameters:
//        - object  The model object.
//        - completion Closure that gets called on completion.
//     */
//    @objc func removeShare(for object: AnyObject, completion: ((Error?) -> ())?) {
//        
//        guard !syncing else {
//            completion?(CloudKitSynchronizer.SyncError.alreadySyncing)
//            return
//        }
//        
//        guard let modelAdapter = modelAdapter(for: object),
//            let share = modelAdapter.share(for: object),
//            let record = modelAdapter.record(for: object) else {
//                completion?(nil)
//                return
//        }
//        
//        syncing = true
//        
//        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: [share.recordID])
//        operation.modifyRecordsCompletionBlock = { savedRecords, deletedRecordIDs, operationError in
//            
//            //            self.dispatchQueue.async {
//            
//            if let savedRecords = savedRecords,
//               operationError == nil {
//                
//                modelAdapter.didUpload(savedRecords: savedRecords)
//                modelAdapter.persistImportedChanges(completion: { (error) in
//                    
//                    //                    self.dispatchQueue.async {
//                    if error == nil {
//                        modelAdapter.deleteShare(for: object)
//                    }
//                    modelAdapter.didFinishImport(with: error)
//                    
////                    DispatchQueue.main.async {
////                    Task(priority: .background) { @BigSyncBackgroundActor in
//                        self.syncing = false
//                        completion?(error)
////                    }
//                    //                    }
//                })
//                
//            } else {
//                
////                DispatchQueue.main.async {
////                Task(priority: .background) { @BigSyncBackgroundActor in
//                    self.syncing = false
//                    completion?(operationError)
////                }
//            }
//            //            }
//        }
//        
//        database.add(operation)
//    }
//}
