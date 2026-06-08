package com.waylo.ui

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import com.waylo.R
import com.waylo.databinding.SheetPermissionsBinding
import com.waylo.permissions.PermissionManager

/**
 * Read-only bottom sheet that shows the status of all four permissions.
 */
class PermissionsSheet : BottomSheetDialogFragment() {

    private var _binding: SheetPermissionsBinding? = null
    private val binding get() = _binding!!

    override fun getTheme(): Int = R.style.Theme_Waylo_BottomSheet

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = SheetPermissionsBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        val ctx = requireContext()

        bindRow(
            binding.rowOverlay,
            getString(R.string.perm_overlay),
            PermissionManager.hasOverlayPermission(ctx)
        )
        bindRow(
            binding.rowAccessibility,
            getString(R.string.perm_accessibility),
            PermissionManager.hasAccessibilityEnabled(ctx)
        )
        bindRow(
            binding.rowCapture,
            getString(R.string.perm_capture),
            PermissionManager.hasScreenCapturePermission()
        )
        bindRow(
            binding.rowMic,
            getString(R.string.perm_microphone),
            PermissionManager.hasMicrophonePermission(ctx)
        )
    }

    private fun bindRow(
        row: com.waylo.databinding.ItemPermissionRowBinding,
        label: String,
        granted: Boolean
    ) {
        row.rowLabel.text = label
        row.rowDot.setBackgroundResource(
            if (granted) R.drawable.badge_green else R.drawable.badge_red
        )
        row.rowStatus.setText(
            if (granted) R.string.status_granted else R.string.status_not_granted
        )
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
