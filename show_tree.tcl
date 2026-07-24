# PrimeTime Tcl: show clock-tree-like fanout hierarchy from a user pin.
#
# Usage:
#   source show_tree.tcl
#   show_tree a/b/c/buf/A
#   show_tree a/b/c/buf/A -l 3
#   show_tree a/b/c/buf/A -node
#   show_tree -node a/b/c/buf/A -l 3
#
# Output:
#   show_tree.rpt

namespace eval ::show_tree {
    variable script_version "2026-07-24.1"
    variable rpt_file "show_tree.rpt"
    variable default_depth_limit 0
    variable max_visit_count 100000
    variable flush_interval 1000
    variable clock_pin_names {CK CP CLK ECK}
    variable macro_ref_patterns {*SRAM* *RAM* *ROM* *RF* *MEM* *MACRO*}
    variable short_owner
    variable full_to_short
    variable mapping_entries
    variable terminal_cache
    variable child_cache
    variable node_pin
    variable node_depth
    variable node_status
    variable node_children
    variable node_label
    variable level_width
    variable tree_node_count
    variable node_display_serial
    variable visit_count
    variable line_count
    variable stopped_by_max_visit
}

proc ::show_tree::safe_attr {obj attr {default ""}} {
    if {[catch {get_attribute $obj $attr} value]} {
        return $default
    }
    return $value
}

proc ::show_tree::bool_attr {obj attr} {
    set value [string tolower [safe_attr $obj $attr ""]]
    return [expr {$value eq "true" || $value eq "1" || $value eq "yes"}]
}

proc ::show_tree::collection_size {collection} {
    if {[catch {sizeof_collection $collection} size]} {
        return 0
    }
    return $size
}

proc ::show_tree::one_object {collection} {
    if {[collection_size $collection] < 1} {
        return ""
    }
    return [index_collection $collection 0]
}

proc ::show_tree::object_name {obj} {
    if {$obj eq ""} {
        return ""
    }
    return [get_object_name $obj]
}

proc ::show_tree::objects_to_sorted_names {collection} {
    set names {}
    if {[collection_size $collection] < 1} {
        return $names
    }

    foreach_in_collection obj $collection {
        lappend names [object_name $obj]
    }
    return [lsort -dictionary -unique $names]
}

proc ::show_tree::get_pin {pin_name} {
    if {[catch {get_pins -quiet $pin_name} pins]} {
        return ""
    }
    return [one_object $pins]
}

proc ::show_tree::get_pin_cell {pin_obj} {
    if {[catch {get_cells -quiet -of_objects $pin_obj} cells]} {
        return ""
    }
    return [one_object $cells]
}

proc ::show_tree::get_lib_cell {cell_obj} {
    if {[catch {get_lib_cells -quiet -of_objects $cell_obj} lib_cells]} {
        return ""
    }
    return [one_object $lib_cells]
}

proc ::show_tree::pin_leaf_name {pin_name} {
    return [lindex [split $pin_name "/"] end]
}

proc ::show_tree::is_output_direction {pin_obj} {
    set direction [string tolower [safe_attr $pin_obj direction ""]]
    return [expr {$direction eq "out" || $direction eq "output" || $direction eq "inout"}]
}

proc ::show_tree::is_input_direction {pin_obj} {
    set direction [string tolower [safe_attr $pin_obj direction ""]]
    return [expr {$direction eq "in" || $direction eq "input" || $direction eq "inout"}]
}

proc ::show_tree::cell_is_sequential {cell_obj} {
    if {$cell_obj eq ""} {
        return 0
    }
    if {[bool_attr $cell_obj is_sequential]} {
        return 1
    }

    set lib_cell [get_lib_cell $cell_obj]
    if {$lib_cell ne "" && [bool_attr $lib_cell is_sequential]} {
        return 1
    }
    return 0
}

proc ::show_tree::cell_is_combinational {cell_obj} {
    if {$cell_obj eq ""} {
        return 0
    }
    if {[bool_attr $cell_obj is_combinational]} {
        return 1
    }

    set lib_cell [get_lib_cell $cell_obj]
    if {$lib_cell ne "" && [bool_attr $lib_cell is_combinational]} {
        return 1
    }

    return 0
}

proc ::show_tree::cell_is_macro {cell_obj} {
    variable macro_ref_patterns

    if {$cell_obj eq ""} {
        return 0
    }

    # is_hierarchical/is_block are not macro-only attributes in PrimeTime.
    # Using them here can classify ordinary hierarchy or wrapper cells as macros.
    foreach attr {is_hard_macro is_macro} {
        if {[bool_attr $cell_obj $attr]} {
            return 1
        }
    }

    set lib_cell [get_lib_cell $cell_obj]
    if {$lib_cell ne ""} {
        foreach attr {is_hard_macro is_macro} {
            if {[bool_attr $lib_cell $attr]} {
                return 1
            }
        }
    }

    set ref_name [safe_attr $cell_obj ref_name ""]
    foreach pattern $macro_ref_patterns {
        if {[string match -nocase $pattern $ref_name]} {
            return 1
        }
    }

    return 0
}

proc ::show_tree::pin_is_clock_name {pin_obj} {
    variable clock_pin_names

    set pin_name [object_name $pin_obj]
    set leaf [string toupper [pin_leaf_name $pin_name]]
    return [expr {[lsearch -exact $clock_pin_names $leaf] >= 0}]
}

proc ::show_tree::pin_is_sequential_clock {pin_obj} {
    set cell_obj [get_pin_cell $pin_obj]
    return [expr {[cell_is_sequential $cell_obj] && [pin_is_clock_name $pin_obj]}]
}

proc ::show_tree::pin_is_terminal {pin_name} {
    set pin_obj [get_pin $pin_name]
    if {$pin_obj eq ""} {
        return 1
    }

    # Every node expanded by write_subtree must be an output pin.
    # Combinational input pins are converted to their cell output pins in
    # get_child_pin_names; leaf input pins are printed and stop here.
    if {![is_output_direction $pin_obj]} {
        return 1
    }

    if {[pin_is_sequential_clock $pin_obj]} {
        return 1
    }

    set cell_obj [get_pin_cell $pin_obj]
    if {$cell_obj ne "" && [cell_is_macro $cell_obj]} {
        return 1
    }

    return 0
}

proc ::show_tree::get_output_pin_names_of_cell {cell_obj} {
    set names {}
    if {[catch {get_pins -quiet -of_objects $cell_obj} pins]} {
        return $names
    }

    foreach_in_collection pin_obj $pins {
        if {[is_output_direction $pin_obj]} {
            lappend names [object_name $pin_obj]
        }
    }

    return [lsort -dictionary -unique $names]
}

proc ::show_tree::get_connected_leaf_pin_names {pin_obj} {
    set pin_name [object_name $pin_obj]
    set connected_names {}

    if {[catch {get_nets -quiet -segments -of_objects $pin_obj} nets]} {
        set nets ""
    }
    if {[collection_size $nets] < 1} {
        if {[catch {get_nets -quiet -of_objects $pin_obj} nets]} {
            set nets ""
        }
    }
    if {[collection_size $nets] < 1} {
        return $connected_names
    }

    foreach_in_collection net_obj $nets {
        if {[catch {all_connected -leaf $net_obj} connected]} {
            continue
        }

        foreach_in_collection connected_obj $connected {
            set connected_name [object_name $connected_obj]
            if {$connected_name eq $pin_name} {
                continue
            }

            set connected_pin [get_pin $connected_name]
            if {$connected_pin eq ""} {
                continue
            }
            if {![is_input_direction $connected_pin]} {
                continue
            }

            lappend connected_names $connected_name
        }
    }

    return [lsort -dictionary -unique $connected_names]
}

proc ::show_tree::get_child_pin_names {pin_name} {
    set pin_obj [get_pin $pin_name]
    if {$pin_obj eq ""} {
        return {}
    }

    set child_names {}
    foreach leaf_pin_name [get_connected_leaf_pin_names $pin_obj] {
        set leaf_pin [get_pin $leaf_pin_name]
        set leaf_cell [get_pin_cell $leaf_pin]

        if {$leaf_cell eq ""} {
            lappend child_names $leaf_pin_name
            continue
        }

        if {[pin_is_sequential_clock $leaf_pin]} {
            lappend child_names $leaf_pin_name
            continue
        }

        if {[cell_is_macro $leaf_cell]} {
            lappend child_names $leaf_pin_name
            continue
        }

        if {![cell_is_combinational $leaf_cell] && [cell_is_sequential $leaf_cell]} {
            lappend child_names $leaf_pin_name
            continue
        }

        set output_pin_names [get_output_pin_names_of_cell $leaf_cell]
        if {[llength $output_pin_names] == 0} {
            lappend child_names $leaf_pin_name
            continue
        }

        foreach output_pin_name $output_pin_names {
            lappend child_names $output_pin_name
        }
    }

    return [lsort -dictionary -unique $child_names]
}

proc ::show_tree::cached_pin_is_terminal {pin_name} {
    variable terminal_cache

    if {![info exists terminal_cache($pin_name)]} {
        set terminal_cache($pin_name) [pin_is_terminal $pin_name]
    }
    return $terminal_cache($pin_name)
}

proc ::show_tree::cached_child_pin_names {pin_name} {
    variable child_cache

    if {![info exists child_cache($pin_name)]} {
        set child_cache($pin_name) [get_child_pin_names $pin_name]
    }
    return $child_cache($pin_name)
}

proc ::show_tree::short_pin_name {pin_name depth} {
    variable short_owner
    variable full_to_short
    variable mapping_entries

    if {[info exists full_to_short($pin_name)]} {
        set short_name $full_to_short($pin_name)
    } else {
        set parts [split $pin_name "/"]
        set count [llength $parts]
        if {$count <= 2} {
            set base_name $pin_name
        } else {
            set short_parts {}
            for {set i 0} {$i < $count} {incr i} {
                set part [lindex $parts $i]
                if {$i < ($count - 2)} {
                    lappend short_parts [string index $part end]
                } else {
                    lappend short_parts $part
                }
            }
            set base_name [join $short_parts "/"]
        }

        set short_name $base_name
        set collision_index 2
        while {[info exists short_owner($short_name)] &&
               $short_owner($short_name) ne $pin_name} {
            set short_name "${base_name}#${collision_index}"
            incr collision_index
        }

        set short_owner($short_name) $pin_name
        set full_to_short($pin_name) $short_name
    }

    if {$short_name ne $pin_name} {
        set mapping_key "$short_name ($depth)"
        set mapping_entries($mapping_key) $pin_name
    }
    return $short_name
}

proc ::show_tree::build_subtree {pin_name depth path depth_limit} {
    variable tree_node_count
    variable node_pin
    variable node_depth
    variable node_status
    variable node_children
    variable visit_count
    variable max_visit_count
    variable stopped_by_max_visit

    set node_id $tree_node_count
    incr tree_node_count
    set node_pin($node_id) $pin_name
    set node_depth($node_id) $depth
    set node_children($node_id) {}

    if {[lsearch -exact $path $pin_name] >= 0} {
        set node_status($node_id) "CYCLE"
        return $node_id
    }

    if {$max_visit_count > 0 && $visit_count >= $max_visit_count} {
        set stopped_by_max_visit 1
        set node_status($node_id) "MAX_VISIT"
        return $node_id
    }

    incr visit_count

    if {$depth_limit > 0 && $depth >= $depth_limit} {
        set node_status($node_id) "MAX_DEPTH"
        return $node_id
    }

    if {[cached_pin_is_terminal $pin_name]} {
        set node_status($node_id) "LEAF"
        return $node_id
    }

    set child_names [cached_child_pin_names $pin_name]
    if {[llength $child_names] == 0} {
        set node_status($node_id) "LEAF"
        return $node_id
    }

    set node_status($node_id) "INTERNAL"
    set child_path [concat $path [list $pin_name]]
    foreach child_name $child_names {
        set child_id [build_subtree $child_name [expr {$depth + 1}] $child_path $depth_limit]
        lappend node_children($node_id) $child_id
    }
    return $node_id
}

proc ::show_tree::assign_node_labels {node_id node_mode} {
    variable node_pin
    variable node_depth
    variable node_status
    variable node_children
    variable node_label
    variable level_width
    variable node_display_serial

    set pin_name $node_pin($node_id)
    set depth $node_depth($node_id)
    if {$node_status($node_id) eq "INTERNAL"} {
        if {$node_mode} {
            if {$depth == 0} {
                set label "$pin_name ($depth)"
            } else {
                set label "o${node_display_serial}_${depth}"
                incr node_display_serial
            }
        } else {
            set label "[short_pin_name $pin_name $depth] ($depth)"
        }
    } else {
        set label "$pin_name ($depth)"
    }

    set node_label($node_id) $label
    set label_width [string length $label]
    if {![info exists level_width($depth)] || $label_width > $level_width($depth)} {
        set level_width($depth) $label_width
    }

    foreach child_id $node_children($node_id) {
        assign_node_labels $child_id $node_mode
    }
}

proc ::show_tree::spaces {count} {
    if {$count <= 0} {
        return ""
    }
    return [string repeat " " $count]
}

proc ::show_tree::write_line {fh line} {
    variable flush_interval
    variable line_count

    puts $fh $line
    incr line_count
    if {$flush_interval > 0 && ($line_count % $flush_interval) == 0} {
        flush $fh
    }
}

proc ::show_tree::status_suffix {status} {
    switch -- $status {
        CYCLE {
            return " \[CYCLE\]"
        }
        MAX_DEPTH {
            return " \[MAX_DEPTH\]"
        }
        MAX_VISIT {
            return " \[MAX_VISIT\]"
        }
        default {
            return ""
        }
    }
}

proc ::show_tree::write_subtree {fh node_id first_prefix rest_prefix} {
    variable node_depth
    variable node_status
    variable node_children
    variable node_label
    variable level_width

    set label $node_label($node_id)
    set status $node_status($node_id)
    if {$status ne "INTERNAL"} {
        write_line $fh "${first_prefix}${label}[status_suffix $status]"
        return
    }

    set depth $node_depth($node_id)
    set column_width $level_width($depth)
    set padded_label "${label}[spaces [expr {$column_width - [string length $label]}]]"
    set child_rest_prefix "${rest_prefix}[spaces [expr {$column_width + 5}]]"
    set is_first_child 1

    foreach child_id $node_children($node_id) {
        if {$is_first_child} {
            set child_first_prefix "${first_prefix}${padded_label} --- "
            set is_first_child 0
        } else {
            set child_first_prefix "${rest_prefix}[spaces $column_width] --- "
        }
        write_subtree $fh $child_id $child_first_prefix $child_rest_prefix
    }
}

proc ::show_tree::write_mapping {fh node_mode} {
    variable mapping_entries

    if {$node_mode} {
        return
    }

    set keys [array names mapping_entries]
    if {[llength $keys] == 0} {
        return
    }

    puts $fh ""
    puts $fh "# short_name (level) => full_name"
    foreach mapping_key [lsort -dictionary $keys] {
        puts $fh "$mapping_key => $mapping_entries($mapping_key)"
    }
}

proc show_tree {args} {
    array unset ::show_tree::short_owner
    array set ::show_tree::short_owner {}
    array unset ::show_tree::full_to_short
    array set ::show_tree::full_to_short {}
    array unset ::show_tree::mapping_entries
    array set ::show_tree::mapping_entries {}
    array unset ::show_tree::terminal_cache
    array set ::show_tree::terminal_cache {}
    array unset ::show_tree::child_cache
    array set ::show_tree::child_cache {}
    array unset ::show_tree::node_pin
    array set ::show_tree::node_pin {}
    array unset ::show_tree::node_depth
    array set ::show_tree::node_depth {}
    array unset ::show_tree::node_status
    array set ::show_tree::node_status {}
    array unset ::show_tree::node_children
    array set ::show_tree::node_children {}
    array unset ::show_tree::node_label
    array set ::show_tree::node_label {}
    array unset ::show_tree::level_width
    array set ::show_tree::level_width {}
    set ::show_tree::tree_node_count 0
    set ::show_tree::node_display_serial 0
    set ::show_tree::visit_count 0
    set ::show_tree::line_count 0
    set ::show_tree::stopped_by_max_visit 0

    set user_pin ""
    set depth_limit $::show_tree::default_depth_limit
    set max_visit_count $::show_tree::max_visit_count
    set node_mode 0
    set argc [llength $args]
    for {set i 0} {$i < $argc} {incr i} {
        set opt [lindex $args $i]
        switch -- $opt {
            -node {
                set node_mode 1
            }
            -l {
                incr i
                if {$i >= $argc} {
                    error "show_tree: missing value for -l."
                }
                set depth_limit [lindex $args $i]
                if {![string is integer -strict $depth_limit] || $depth_limit < 0} {
                    error "show_tree: -l must be a non-negative integer. 0 means no limit."
                }
            }
            -max_nodes {
                incr i
                if {$i >= $argc} {
                    error "show_tree: missing value for -max_nodes."
                }
                set max_visit_count [lindex $args $i]
                if {![string is integer -strict $max_visit_count] || $max_visit_count < 0} {
                    error "show_tree: -max_nodes must be a non-negative integer. 0 means no limit."
                }
            }
            default {
                if {[string match "-*" $opt]} {
                    error "show_tree: unknown option '$opt'. Usage: show_tree ?-node? <pin> ?-l depth? ?-max_nodes count?"
                }
                if {$user_pin ne ""} {
                    error "show_tree: multiple pins specified ('$user_pin' and '$opt'). Please provide one exact pin."
                }
                set user_pin $opt
            }
        }
    }
    if {$user_pin eq ""} {
        error "show_tree: missing pin. Usage: show_tree ?-node? <pin> ?-l depth? ?-max_nodes count?"
    }
    set ::show_tree::max_visit_count $max_visit_count

    if {[catch {get_cells -quiet $user_pin} user_cells]} {
        set user_cells ""
    }
    if {[::show_tree::collection_size $user_cells] > 0} {
        error "show_tree: '$user_pin' is a cell. Please provide a pin."
    }

    if {[catch {get_pins -quiet $user_pin} user_pins]} {
        set user_pins ""
    }
    set user_pin_count [::show_tree::collection_size $user_pins]
    if {$user_pin_count == 0} {
        error "show_tree: cannot find pin '$user_pin'."
    }
    if {$user_pin_count > 1} {
        error "show_tree: '$user_pin' matches $user_pin_count pins. Please provide one exact pin."
    }
    set user_pin_obj [::show_tree::one_object $user_pins]

    set user_cell [::show_tree::get_pin_cell $user_pin_obj]
    if {$user_cell eq ""} {
        error "show_tree: '$user_pin' is not a cell pin."
    }

    set root_pin_names [::show_tree::get_output_pin_names_of_cell $user_cell]
    if {[llength $root_pin_names] == 0} {
        error "show_tree: cell '[get_object_name $user_cell]' has no output pins."
    }

    set fh [open $::show_tree::rpt_file w]
    puts $fh "# show_tree report"
    puts $fh "# script_version: $::show_tree::script_version"
    puts $fh "# user_pin: [get_object_name $user_pin_obj]"
    puts $fh "# root_cell: [get_object_name $user_cell]"
    puts $fh "# root_output_pins: [llength $root_pin_names]"
    puts $fh "# depth_limit: $depth_limit"
    puts $fh "# max_nodes: $max_visit_count"
    puts $fh "# node_mode: $node_mode"
    puts $fh ""
    flush $fh

    puts "show_tree: scanning connectivity..."
    set root_node_ids {}
    foreach root_pin_name $root_pin_names {
        lappend root_node_ids [::show_tree::build_subtree $root_pin_name 0 {} $depth_limit]
    }

    foreach root_node_id $root_node_ids {
        ::show_tree::assign_node_labels $root_node_id $node_mode
    }

    puts "show_tree: writing aligned report..."
    foreach root_node_id $root_node_ids {
        ::show_tree::write_subtree $fh $root_node_id "" ""
        puts $fh ""
        flush $fh
    }

    ::show_tree::write_mapping $fh $node_mode
    puts $fh ""
    puts $fh "# traversed_nodes: $::show_tree::visit_count"
    puts $fh "# tree_nodes: $::show_tree::tree_node_count"
    puts $fh "# report_lines: $::show_tree::line_count"
    if {$::show_tree::stopped_by_max_visit} {
        puts $fh "# WARNING: traversal stopped by max_nodes limit."
    }
    close $fh

    puts "show_tree: wrote $::show_tree::rpt_file (version $::show_tree::script_version)"
}
