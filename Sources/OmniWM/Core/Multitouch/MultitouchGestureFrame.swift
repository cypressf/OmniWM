// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreHID
import Foundation
import IOKit
import os
import Synchronization

private let multitouchTouchStride = 96
private let multitouchStateByteOffset = 20
private let multitouchPositionXByteOffset = 32
private let multitouchPositionYByteOffset = 36
private let multitouchSizeByteOffset = 48
private let multitouchMajorAxisByteOffset = 60
private let multitouchMinorAxisByteOffset = 64
private let multitouchTouchingState: Int32 = 4

struct MultitouchContactSession: Equatable, Sendable {
    let generation: UInt
    let slot: Int
    let session: UInt64
    let senderId: UInt64?
}

struct MultitouchContactSessions: Sendable {
    var generation: UInt = 0
    var sessions = InlineArray<64, UInt64>(repeating: 0)

    func contains(_ contact: MultitouchContactSession) -> Bool {
        generation != 0 && contact.generation == generation
            && contact.slot >= 0 && contact.slot < sessions.count
            && contact.session != 0 && sessions[contact.slot] == contact.session
    }
}

extension MultitouchGestureSource {
    struct RawTouch: Sendable {
        let x: Float
        let y: Float
        /// Contact ellipse axes and total pressure as reported by the sensor; 0 when the frame carries none.
        var majorAxis: Float = 0
        var minorAxis: Float = 0
        var size: Float = 0
    }

    struct RawTouchBuffer: RandomAccessCollection, Sendable {
        private var inline = InlineArray<16, RawTouch>(repeating: RawTouch(x: 0, y: 0))
        private var overflow: [RawTouch] = []
        private(set) var count = 0

        var startIndex: Int {
            0
        }

        var endIndex: Int {
            count
        }

        init() {}

        init(_ touches: [RawTouch]) {
            for touch in touches {
                append(touch)
            }
        }

        mutating func append(_ touch: RawTouch) {
            if count < inline.count {
                inline[count] = touch
            } else {
                overflow.append(touch)
            }
            count += 1
        }

        subscript(index: Int) -> RawTouch {
            index < inline.count ? inline[index] : overflow[index - inline.count]
        }
    }

    struct RawFrame: Sendable {
        let touches: RawTouchBuffer
        let timestamp: Double
        /// Touching contacts the decoder dropped as palms, and the widest major axis among them.
        let rejectedPalmCount: Int
        let rejectedPalmMajorAxis: Float

        init(touches: [RawTouch], timestamp: Double, rejectedPalmCount: Int = 0, rejectedPalmMajorAxis: Float = 0) {
            self.touches = RawTouchBuffer(touches)
            self.timestamp = timestamp
            self.rejectedPalmCount = rejectedPalmCount
            self.rejectedPalmMajorAxis = rejectedPalmMajorAxis
        }

        init(
            touches: consuming RawTouchBuffer,
            timestamp: Double,
            rejectedPalmCount: Int = 0,
            rejectedPalmMajorAxis: Float = 0
        ) {
            self.touches = consume touches
            self.timestamp = timestamp
            self.rejectedPalmCount = rejectedPalmCount
            self.rejectedPalmMajorAxis = rejectedPalmMajorAxis
        }
    }

    /// Contacts whose ellipse major axis exceeds this are palms, not fingertips. Fingertips on Apple
    /// trackpads report a major axis of roughly 6-12; the heel of a palm or the side of a thumb reports
    /// 20 and up. Contacts that carry no size data (0) are always accepted. Tune against the
    /// "multitouch:" lines of the mouse trace, which list every contact's axes whenever the count changes.
    nonisolated static let palmMajorAxisThreshold: Float = 20

    nonisolated static func isPalm(majorAxis: Float) -> Bool {
        majorAxis.isFinite && majorAxis > palmMajorAxisThreshold
    }

    /// One line per change in contact or palm count, carrying each contact's ellipse axes and pressure so
    /// the palm threshold can be tuned from a captured mouse trace.
    static func describeContacts(_ frame: RawFrame) -> String {
        let contacts = frame.touches.map { touch in
            String(format: "%.1fx%.1f z%.2f", touch.majorAxis, touch.minorAxis, touch.size)
        }.joined(separator: ", ")
        var line = "multitouch: \(frame.touches.count) contacts [\(contacts)]"
        if frame.rejectedPalmCount > 0 {
            line += String(
                format: ", %d rejected as palm (major %.1f)",
                frame.rejectedPalmCount,
                frame.rejectedPalmMajorAxis
            )
        }
        return line
    }

    static func makeSnapshot(
        frame: RawFrame,
        location: CGPoint,
        previousActiveCount: Int,
        terminalPhase: NSEvent.Phase = .ended,
        contactSession: MultitouchContactSession? = nil
    ) -> (snapshot: MouseEventHandler.GestureEventSnapshot?, activeCount: Int) {
        let activeCount = frame.touches.count
        if activeCount == 0 {
            guard previousActiveCount > 0 else { return (nil, 0) }
            return (
                liftSnapshot(
                    terminalPhase,
                    location: location,
                    timestamp: frame.timestamp,
                    contactSession: contactSession
                ),
                0
            )
        }

        let phase: NSEvent.Phase = previousActiveCount == 0 ? .began : .changed
        let touches = frame.touches.map { touch in
            MouseEventHandler.GestureTouchSample(
                phase: .moved,
                normalizedPosition: normalizedPosition(x: touch.x, y: touch.y)
            )
        }
        let snapshot = MouseEventHandler.GestureEventSnapshot(
            location: location,
            phaseRawValue: phase.rawValue,
            timestamp: frame.timestamp,
            touches: touches,
            contactSession: contactSession
        )
        return (snapshot, activeCount)
    }

    static func liftSnapshot(
        _ phase: NSEvent.Phase,
        location: CGPoint,
        timestamp: Double,
        contactSession: MultitouchContactSession? = nil
    ) -> MouseEventHandler.GestureEventSnapshot {
        MouseEventHandler.GestureEventSnapshot(
            location: location,
            phaseRawValue: phase.rawValue,
            timestamp: timestamp,
            touches: [],
            contactSession: contactSession
        )
    }

    private static func normalizedPosition(x: Float, y: Float) -> CGPoint? {
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    /// Decodes a MultitouchSupport contact frame. Raw frames arrive before Apple's palm rejection, so a
    /// resting palm shows up as an ordinary touching contact; it is dropped here by contact size.
    nonisolated static func buildRawFrame(
        fingers: UnsafeMutableRawPointer?,
        count: Int32,
        timestamp: Double
    ) -> RawFrame {
        guard let fingers, count > 0 else { return RawFrame(touches: [], timestamp: timestamp) }
        var touches = RawTouchBuffer()
        var rejectedPalmCount = 0
        var rejectedPalmMajorAxis: Float = 0
        for index in 0 ..< Int(count) {
            let base = index * multitouchTouchStride
            let state = fingers.load(fromByteOffset: base + multitouchStateByteOffset, as: Int32.self)
            guard state == multitouchTouchingState else { continue }
            let majorAxis = fingers.load(fromByteOffset: base + multitouchMajorAxisByteOffset, as: Float.self)
            if isPalm(majorAxis: majorAxis) {
                rejectedPalmCount += 1
                rejectedPalmMajorAxis = max(rejectedPalmMajorAxis, majorAxis)
                continue
            }
            let x = fingers.load(fromByteOffset: base + multitouchPositionXByteOffset, as: Float.self)
            let y = fingers.load(fromByteOffset: base + multitouchPositionYByteOffset, as: Float.self)
            let minorAxis = fingers.load(fromByteOffset: base + multitouchMinorAxisByteOffset, as: Float.self)
            let size = fingers.load(fromByteOffset: base + multitouchSizeByteOffset, as: Float.self)
            touches.append(RawTouch(x: x, y: y, majorAxis: majorAxis, minorAxis: minorAxis, size: size))
        }
        return RawFrame(
            touches: touches,
            timestamp: timestamp,
            rejectedPalmCount: rejectedPalmCount,
            rejectedPalmMajorAxis: rejectedPalmMajorAxis
        )
    }
}
