// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class MultitouchGestureSourceTests: XCTestCase {
    private let location = CGPoint(x: 100, y: 200)

    private func frame(
        _ positions: [(Float, Float)],
        timestamp: Double = 1.0
    ) -> MultitouchGestureSource.RawFrame {
        MultitouchGestureSource.RawFrame(
            touches: positions.map { MultitouchGestureSource.RawTouch(x: $0.0, y: $0.1) },
            timestamp: timestamp
        )
    }

    func testNoTouchesWhileIdleProducesNoSnapshot() {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([]),
            location: location,
            previousActiveCount: 0
        )
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.activeCount, 0)
    }

    func testFirstContactBeginsGesture() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.5, 0.5), (0.55, 0.5), (0.6, 0.5)]),
            location: location,
            previousActiveCount: 0
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.phaseRawValue, NSEvent.Phase.began.rawValue)
        XCTAssertEqual(result.activeCount, 3)
        XCTAssertEqual(snapshot.touches.count, 3)
        XCTAssertEqual(snapshot.location, location)
    }

    func testContinuedContactReportsChanged() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.4, 0.5), (0.45, 0.5), (0.5, 0.5)]),
            location: location,
            previousActiveCount: 3
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.phaseRawValue, NSEvent.Phase.changed.rawValue)
        XCTAssertEqual(result.activeCount, 3)
    }

    func testFingerLiftEndsGestureCleanly() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([]),
            location: location,
            previousActiveCount: 3
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.phaseRawValue, NSEvent.Phase.ended.rawValue)
        XCTAssertTrue(snapshot.touches.isEmpty)
        XCTAssertEqual(result.activeCount, 0)
    }

    func testPartialLiftStillReportsLoweredCount() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.4, 0.5), (0.45, 0.5)]),
            location: location,
            previousActiveCount: 3
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.phaseRawValue, NSEvent.Phase.changed.rawValue)
        XCTAssertEqual(result.activeCount, 2)
    }

    func testNormalizedPositionsArePropagated() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.25, 0.75)]),
            location: location,
            previousActiveCount: 0
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        let touch = try XCTUnwrap(snapshot.touches.first)
        XCTAssertEqual(touch.phase, .moved)
        XCTAssertEqual(touch.normalizedPosition, CGPoint(x: 0.25, y: 0.75))
    }

    func testNonFiniteContactPositionSanitizesToNil() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(.nan, 0.5)]),
            location: location,
            previousActiveCount: 0
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        let touch = try XCTUnwrap(snapshot.touches.first)
        XCTAssertNil(touch.normalizedPosition)
    }

    func testInlineTouchStoragePreservesOverflowContacts() throws {
        let positions = (0 ..< 20).map { index in
            (Float(index) / 20, Float(20 - index) / 20)
        }
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame(positions),
            location: location,
            previousActiveCount: 0
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        let lastPosition = try XCTUnwrap(snapshot.touches.last?.normalizedPosition)

        XCTAssertEqual(result.activeCount, 20)
        XCTAssertEqual(snapshot.touches.count, 20)
        XCTAssertEqual(lastPosition.x, 0.95, accuracy: 0.0001)
        XCTAssertEqual(lastPosition.y, 0.05, accuracy: 0.0001)
    }

    func testTimestampIsPropagated() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.5, 0.5), (0.55, 0.5), (0.6, 0.5)], timestamp: 42.5),
            location: location,
            previousActiveCount: 0
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.timestamp, 42.5)
    }

    func testGestureLifecycleProducesBeganChangedEnded() throws {
        var previousActiveCount = 0

        let down = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.5, 0.5), (0.55, 0.5), (0.6, 0.5)]),
            location: location,
            previousActiveCount: previousActiveCount
        )
        XCTAssertEqual(try XCTUnwrap(down.snapshot).phaseRawValue, NSEvent.Phase.began.rawValue)
        previousActiveCount = down.activeCount

        let move = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.4, 0.5), (0.45, 0.5), (0.5, 0.5)]),
            location: location,
            previousActiveCount: previousActiveCount
        )
        XCTAssertEqual(try XCTUnwrap(move.snapshot).phaseRawValue, NSEvent.Phase.changed.rawValue)
        previousActiveCount = move.activeCount

        let lift = MultitouchGestureSource.makeSnapshot(
            frame: frame([]),
            location: location,
            previousActiveCount: previousActiveCount
        )
        XCTAssertEqual(try XCTUnwrap(lift.snapshot).phaseRawValue, NSEvent.Phase.ended.rawValue)
        XCTAssertEqual(lift.activeCount, 0)
    }

    // MARK: - Palm rejection in the raw frame decoder

    private typealias RawContact = (x: Float, y: Float, majorAxis: Float, minorAxis: Float, size: Float, state: Int32)

    private func decodedFrame(_ contacts: [RawContact], timestamp: Double = 1.0) -> MultitouchGestureSource.RawFrame {
        let stride = 96
        let byteCount = max(contacts.count, 1) * stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        defer { buffer.deallocate() }
        for (index, contact) in contacts.enumerated() {
            let base = index * stride
            buffer.storeBytes(of: contact.state, toByteOffset: base + 20, as: Int32.self)
            buffer.storeBytes(of: contact.x, toByteOffset: base + 32, as: Float.self)
            buffer.storeBytes(of: contact.y, toByteOffset: base + 36, as: Float.self)
            buffer.storeBytes(of: contact.size, toByteOffset: base + 48, as: Float.self)
            buffer.storeBytes(of: contact.majorAxis, toByteOffset: base + 60, as: Float.self)
            buffer.storeBytes(of: contact.minorAxis, toByteOffset: base + 64, as: Float.self)
        }
        return MultitouchGestureSource.buildRawFrame(
            fingers: buffer,
            count: Int32(contacts.count),
            timestamp: timestamp
        )
    }

    func testDecoderDropsPalmSizedContacts() throws {
        let threshold = MultitouchGestureSource.palmMajorAxisThreshold
        let fingertip = threshold / 2
        let frame = decodedFrame([
            (0.3, 0.5, fingertip, fingertip, 1.2, 4),
            (0.4, 0.5, fingertip, fingertip, 1.3, 4),
            (0.5, 0.5, fingertip, fingertip, 1.1, 4),
            (0.6, 0.9, threshold * 1.5, 12, 6.0, 4)
        ])

        XCTAssertEqual(frame.touches.count, 3, "the palm must not count as a fourth finger")
        XCTAssertEqual(frame.rejectedPalmCount, 1)
        XCTAssertEqual(frame.rejectedPalmMajorAxis, threshold * 1.5)
        let first = try XCTUnwrap(frame.touches.first)
        XCTAssertEqual(first.x, 0.3)
        XCTAssertEqual(first.majorAxis, fingertip)
        XCTAssertEqual(first.minorAxis, fingertip)
        XCTAssertEqual(first.size, 1.2)
    }

    func testDecoderKeepsContactsWithoutSizeDataAndAtTheThreshold() {
        let threshold = MultitouchGestureSource.palmMajorAxisThreshold
        let frame = decodedFrame([
            (0.3, 0.5, 0, 0, 0, 4),
            (0.4, 0.5, threshold, threshold, 2, 4)
        ])

        XCTAssertEqual(frame.touches.count, 2)
        XCTAssertEqual(frame.rejectedPalmCount, 0)
        XCTAssertEqual(frame.rejectedPalmMajorAxis, 0)
    }

    func testDecoderIgnoresPalmsThatAreNotTouching() {
        let threshold = MultitouchGestureSource.palmMajorAxisThreshold
        let frame = decodedFrame([
            (0.3, 0.5, 8, 7, 1, 4),
            (0.6, 0.9, threshold * 2, 12, 0.2, 2)
        ])

        XCTAssertEqual(frame.touches.count, 1)
        XCTAssertEqual(frame.rejectedPalmCount, 0, "a hovering palm was never a contact to reject")
    }

    func testDecoderRejectsEveryPalmAndReportsTheWidest() {
        let threshold = MultitouchGestureSource.palmMajorAxisThreshold
        let frame = decodedFrame([
            (0.2, 0.9, threshold + 1, 10, 4, 4),
            (0.8, 0.9, threshold + 9, 14, 7, 4)
        ])

        XCTAssertEqual(frame.touches.count, 0)
        XCTAssertEqual(frame.rejectedPalmCount, 2)
        XCTAssertEqual(frame.rejectedPalmMajorAxis, threshold + 9)
    }

    func testContactTraceListsAxesAndRejectedPalms() {
        let frame = MultitouchGestureSource.RawFrame(
            touches: [
                MultitouchGestureSource.RawTouch(x: 0.3, y: 0.5, majorAxis: 8.25, minorAxis: 7, size: 1.5),
                MultitouchGestureSource.RawTouch(x: 0.4, y: 0.5, majorAxis: 9, minorAxis: 7.5, size: 1.75)
            ],
            timestamp: 1.0,
            rejectedPalmCount: 1,
            rejectedPalmMajorAxis: 30
        )

        XCTAssertEqual(
            MultitouchGestureSource.describeContacts(frame),
            "multitouch: 2 contacts [8.2x7.0 z1.50, 9.0x7.5 z1.75], 1 rejected as palm (major 30.0)"
        )
    }

    func testContactTraceOmitsPalmClauseWhenNothingWasRejected() {
        let frame = MultitouchGestureSource.RawFrame(
            touches: [MultitouchGestureSource.RawTouch(x: 0.3, y: 0.5)],
            timestamp: 1.0
        )

        XCTAssertEqual(MultitouchGestureSource.describeContacts(frame), "multitouch: 1 contacts [0.0x0.0 z0.00]")
    }
}
