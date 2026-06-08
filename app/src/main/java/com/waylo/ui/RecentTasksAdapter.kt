package com.waylo.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.waylo.R

/**
 * Placeholder "ghost" list of recent tasks. Real persistence arrives in Week 3;
 * for now these are static skeleton rows.
 */
class RecentTasksAdapter(
    private val items: List<String>
) : RecyclerView.Adapter<RecentTasksAdapter.VH>() {

    class VH(view: View) : RecyclerView.ViewHolder(view) {
        val title: TextView = view.findViewById(R.id.recentTitle)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_recent_skeleton, parent, false)
        return VH(view)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        holder.title.text = items[position]
    }

    override fun getItemCount(): Int = items.size
}
