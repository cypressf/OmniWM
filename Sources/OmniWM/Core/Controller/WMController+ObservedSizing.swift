// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func adoptObservedMinimumAfterStableSizeClamp(_ result: AXFrameApplyResult) {
        // While the user drags a size, apps that snap to increments (Terminal's character grid) round
        // every resting target up or down by less than a cell; treating a round-up as the window's
        // minimum would stop the drag from ever shrinking it again. The frame the drag settles on is
        // the one worth learning from.
        guard !mouseEventHandler.isInteractiveResizeActive,
              let entry = workspaceManager.entry(forPid: result.pid, windowId: result.windowId),
              sameAXWindowIdentity(entry.axRef, result.expectedWindow),
              entry.mode == .tiling,
              entry.layoutReason == .standard,
              entry.hiddenState == nil,
              !workspaceManager.isAppHidden(pid: entry.pid),
              let observed = result.writeResult.observedFrame?.size
        else {
            return
        }
        let target = result.targetFrame.size
        let existing = workspaceManager.observedMinSize(for: entry.token) ?? CGSize(width: 1, height: 1)
        let observedMin = CGSize(
            width: observed.width > target.width + FrameTolerance.frameWrite
                ? max(existing.width, observed.width) : existing.width,
            height: observed.height > target.height + FrameTolerance.frameWrite
                ? max(existing.height, observed.height) : existing.height
        )
        adoptObservedMinimum(observedMin, for: entry)
    }

    func adoptObservedMinimumAfterTerminalSizeWriteFailure(_ refusal: AXFrameTerminalRefusal) {
        guard case .sizeWriteFailed = refusal.failureReason,
              let entry = workspaceManager.entry(forWindowId: refusal.windowId),
              entry.mode == .tiling,
              workspaceManager.hiddenState(for: entry.token) == nil
        else {
            return
        }
        let token = entry.token

        let target = refusal.targetFrame.size
        let observed = refusal.observedFrame.size
        let existing = workspaceManager.observedMinSize(for: token) ?? CGSize(width: 1, height: 1)
        let observedMin = CGSize(
            width: Self.updatedObservedMinimumAxis(
                existing: existing.width,
                target: target.width,
                observed: observed.width
            ),
            height: Self.updatedObservedMinimumAxis(
                existing: existing.height,
                target: target.height,
                observed: observed.height
            )
        )
        guard observedMin.width > 1 || observedMin.height > 1 else { return }
        adoptObservedMinimum(observedMin, for: entry)
    }

    /// An interactive resize re-tests every learned minimum in the workspace so the drag can push
    /// windows below sizes that were only ever increment rounding. Apps that truly refuse to shrink
    /// re-teach their minimum from the frame the resize settles on.
    @discardableResult
    func forgetObservedMinimums(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        var forgot = false
        for entry in workspaceManager.entries(in: workspaceId) where entry.mode == .tiling {
            if workspaceManager.clearObservedMinSize(for: entry.token) {
                forgot = true
            }
        }
        if forgot {
            workspaceManager.invalidateLayout(for: [workspaceId])
        }
        return forgot
    }

    private func adoptObservedMinimum(_ observedMin: CGSize, for entry: WindowState) {
        guard workspaceManager.setObservedMinSize(observedMin, for: entry.token) else { return }
        workspaceManager.invalidateLayout(for: [entry.workspaceId])
        layoutRefreshController.requestRelayout(
            reason: .observedConstraintsChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private static func updatedObservedMinimumAxis(
        existing: CGFloat,
        target: CGFloat,
        observed: CGFloat
    ) -> CGFloat {
        if observed > target + FrameTolerance.frameWrite { return observed }
        if target < existing - FrameTolerance.frameWrite { return 1 }
        return existing
    }

    func evaluateSizeConstraints(
        for token: WindowToken,
        axRef: AXWindowRef,
        admissionGeometry: WindowAdmissionGeometryEvidence? = nil
    ) -> WindowSizeConstraints {
        if let cached = workspaceManager.cachedConstraints(for: token) {
            return cached
        }

        let currentSize = admissionGeometry?.frame?.size
            ?? AXWindowService.framePreferFast(axRef)?.size
            ?? axManager.lastAppliedFrame(for: token.windowId)?.size
        let resolved = AXWindowService.sizeConstraints(axRef, currentSize: currentSize)
        workspaceManager.setCachedConstraints(resolved, for: token)
        return resolved
    }
}
