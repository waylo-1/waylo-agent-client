package com.waylo.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.waylo.R

/**
 * List of the user's real recent tasks (see [com.waylo.data.RecentTasksStore]).
 * Tapping a row starts guidance for that task again via [onItemClick].
 */
class RecentTasksAdapter(
    private val items: List<String>,
    private val onItemClick: (String) -> Unit
) : RecyclerView.Adapter<RecentTasksAdapter.VH>() {

    class VH(view: View) : RecyclerView.ViewHolder(view) {
        val title: TextView = view.findViewById(R.id.recentTitle)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_recent_task, parent, false)
        return VH(view)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        val task = items[position]
        holder.title.text = task
        holder.itemView.setOnClickListener { onItemClick(task) }
    }

    override fun getItemCount(): Int = items.size
}
