//
//  SyncedDeletable.swift
//  BigSyncKit
//
//  Created by Alex Ehlke on 2021-10-10.
//

import Foundation
import RealmSwift

@objc public protocol ChangeMetadataRecordable: SoftDeletable {
    var createdAt: Date { get }
    var modifiedAt: Date { get set }
}

@objc public protocol SoftDeletable {
    var isDeleted: Bool { get set }
}

public protocol SyncableBase: RealmSwift.Object, Identifiable, SoftDeletable, Codable {
    var modifiedAt: Date { get }
    var needsSyncToServer: Bool { get }
}

public protocol UnownedSyncableObject: SyncableBase {
}

public protocol SyncableObject: SyncableBase {
    var ownerID: Int? { get }
}
