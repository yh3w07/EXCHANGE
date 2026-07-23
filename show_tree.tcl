# PrimeTime Tcl: show clock-tree-like fanout hierarchy from a user pin.
#
# Usage:
#   source show_tree.tcl
#   show_tree a/b/c/buf/A
#   show_tree a/b/c/buf/A -l 3
#
# Output:
#   show_tree.rpt

namespace eval ::show_tree {
    variable rpt_file "show_tree.rpt"
    variable default_depth_limit 0
    variable clock_pin_names {CK CP CLK ECK}
    variable macro_ref_patterns {*SRAM* *RAM* *ROM* *RF* *MEM* *MACRO*}
    variable short_to_full
    variable full_to_short
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

    foreach attr {is_hard_macro is_macro is_block is_hierarchical} {
        if {[bool_attr $cell_obj $attr]} {
            return 1
        }
    }

    set lib_cell [get_lib_cell $cell_obj]
    if {$lib_cell ne ""} {
        foreach attr {is_hard_macro is_macro is_block is_hierarchical} {
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

proc ::show_tree::short_pin_name {pin_name} {
    variable short_to_full
    variable full_to_short

    set parts [split $pin_name "/"]
    set count [llength $parts]
    if {$count <= 2} {
        set short_name $pin_name
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
        set short_name [join $short_parts "/"]
    }

    if {$short_name ne $pin_name} {
        if {[info exists full_to_short($pin_name)]} {
            return $full_to_short($pin_name)
        }

        if {![info exists short_to_full($short_name)]} {
            set short_to_full($short_name) $pin_name
        } elseif {$short_to_full($short_name) ne $pin_name} {
            set base_name $short_name
            set index 2
            while {[info exists short_to_full("${base_name}#${index}")]} {
                incr index
            }
            set short_name "${base_name}#${index}"
            set short_to_full($short_name) $pin_name
        }
        set full_to_short($pin_name) $short_name
    }

    return $short_name
}

proc ::show_tree::spaces {count} {
    if {$count <= 0} {
        return ""
    }
    return [string repeat " " $count]
}

proc ::show_tree::format_subtree {pin_name depth path depth_limit} {
    set label "[short_pin_name $pin_name] ($depth)"
    if {[lsearch -exact $path $pin_name] >= 0} {
        return [list "$label \[CYCLE\]"]
    }
    if {$depth_limit > 0 && $depth >= $depth_limit} {
        return [list "$label \[MAX_DEPTH\]"]
    }

    set child_names [get_child_pin_names $pin_name]
    if {[llength $child_names] == 0} {
        return [list $label]
    }

    set lines {}
    set is_first_child 1
    set child_path [concat $path [list $pin_name]]

    foreach child_name $child_names {
        set child_lines [format_subtree $child_name [expr {$depth + 1}] $child_path $depth_limit]
        set child_first_line [lindex $child_lines 0]
        set child_rest_lines [lrange $child_lines 1 end]

        if {$is_first_child} {
            lappend lines "$label --- $child_first_line"
            set is_first_child 0
        } else {
            lappend lines "[spaces [string length $label]] --- $child_first_line"
        }

        set continue_prefix [spaces [expr {[string length $label] + 5}]]
        foreach child_line $child_rest_lines {
            lappend lines "$continue_prefix$child_line"
        }
    }

    return $lines
}

proc ::show_tree::write_mapping {fh} {
    variable short_to_full

    set keys [array names short_to_full]
    if {[llength $keys] == 0} {
        return
    }

    puts $fh ""
    puts $fh "# short_name => full_name"
    foreach short_name [lsort -dictionary $keys] {
        puts $fh "$short_name => $short_to_full($short_name)"
    }
}

proc show_tree {user_pin args} {
    array unset ::show_tree::short_to_full
    array set ::show_tree::short_to_full {}
    array unset ::show_tree::full_to_short
    array set ::show_tree::full_to_short {}

    set depth_limit $::show_tree::default_depth_limit
    set argc [llength $args]
    for {set i 0} {$i < $argc} {incr i} {
        set opt [lindex $args $i]
        switch -- $opt {
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
            default {
                error "show_tree: unknown option '$opt'. Usage: show_tree <pin> ?-l depth?"
            }
        }
    }

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
    puts $fh "# user_pin: [get_object_name $user_pin_obj]"
    puts $fh "# root_cell: [get_object_name $user_cell]"
    puts $fh "# root_output_pins: [llength $root_pin_names]"
    puts $fh "# depth_limit: $depth_limit"
    puts $fh ""

    foreach root_pin_name $root_pin_names {
        foreach line [::show_tree::format_subtree $root_pin_name 0 {} $depth_limit] {
            puts $fh $line
        }
        puts $fh ""
    }

    ::show_tree::write_mapping $fh
    close $fh

    puts "show_tree: wrote $::show_tree::rpt_file"
}
