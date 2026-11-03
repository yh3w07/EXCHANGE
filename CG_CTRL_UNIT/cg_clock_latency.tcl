# Clock latency analysis for an already loaded PrimeTime current_design.
# v2.0: start at sub-block clock inputs (TOP=level 1, first analyzed level=2).
# Only two files: hierarchy.rpt and estimated_latency.rpt.
# source cg_clock_latency.tcl
# ::cg_latency::run -max_level 3 -out_dir ./cg_latency_results
namespace eval ::cg_latency {
    variable version 2.0
    variable windows_cache {}
    variable cell_cache {}
}


proc ::cg_latency::finite {x} {
    if {![string is double -strict $x]} {return 0}
    if {[catch {expr {abs(double($x)) < 1.0e100}} ok]} {return 0}
    return $ok
}

proc ::cg_latency::matches {s patterns} {
    foreach p $patterns {if {[string match $p $s]} {return 1}}
    return 0
}

proc ::cg_latency::attr {obj name {default {}}} {
    if {[catch {get_attribute -quiet $obj $name} value] || $value eq {}} {return $default}
    return $value
}

proc ::cg_latency::truth {value} {
    expr {[string tolower $value] in {true 1 yes}}
}

proc ::cg_latency::quantile {sorted p} {
    set n [llength $sorted]
    if {$n == 0} {return {}}
    set position [expr {($n-1)*$p}]
    set lo [expr {int(floor($position))}]
    set hi [expr {int(ceil($position))}]
    expr {[lindex $sorted $lo] + ($position-$lo)*([lindex $sorted $hi]-[lindex $sorted $lo])}
}

proc ::cg_latency::summary {values} {
    set n [llength $values]
    if {$n == 0} {
        return [dict create count 0 mean {} median {} p10 {} p90 {} min {} max {}]
    }
    set sorted [lsort -real $values]
    set mean 0.0
    set i 0
    foreach x $values {incr i; set mean [expr {$mean+($x-$mean)/$i}]}
    return [dict create count $n mean $mean median [quantile $sorted 0.5] \
        p10 [quantile $sorted 0.1] p90 [quantile $sorted 0.9] \
        min [lindex $sorted 0] max [lindex $sorted end]]
}

proc ::cg_latency::fence {values multiplier min_samples} {
    set n [llength $values]
    if {$multiplier == 0} {return [dict create active 0 reason disabled]}
    if {$n < $min_samples} {return [dict create active 0 reason small_sample]}
    set sorted [lsort -real $values]
    set q1 [quantile $sorted 0.25]
    set q3 [quantile $sorted 0.75]
    set iqr [expr {$q3-$q1}]
    if {$iqr <= 1.0e-12} {return [dict create active 0 reason zero_iqr]}
    return [dict create active 1 reason iqr \
        low [expr {$q1-$multiplier*$iqr}] high [expr {$q3+$multiplier*$iqr}]]
}

proc ::cg_latency::inside {x bounds} {
    expr {![dict get $bounds active] || \
        ($x >= [dict get $bounds low] && $x <= [dict get $bounds high])}
}

# PT commonly wraps the window list in one extra list for a single-object query.
# Accept direct and wrapped lists, but never treat an unknown format as zero arrival.
# Each window: {clock_name source_edge {min_r_f rise fall} {max_r_f rise fall}}.

proc ::cg_latency::parse_windows {raw delay_type clock_patterns} {
    set pending [list [list $raw 0]]
    set result {}
    while {[llength $pending]} {
        set item [lindex $pending end]
        set pending [lreplace $pending end end]
        lassign $item node depth
        if {[catch {llength $node} length]} {continue}
        if {$length >= 4 && [lindex $node 1] in {pos_edge neg_edge}} {
            set clock_name [lindex $node 0]
            if {![matches $clock_name $clock_patterns]} {continue}
            set tag "${delay_type}_r_f"
            set arrival {}
            foreach part [lrange $node 2 end] {
                if {[lindex $part 0] ne $tag} {continue}
                foreach x [lrange $part 1 2] {
                    if {![finite $x]} {continue}
                    if {$arrival eq {} || ($delay_type eq "max" && $x > $arrival) || \
                        ($delay_type eq "min" && $x < $arrival)} {set arrival $x}
                }
            }
            if {$arrival eq {}} {continue}
            set key [list $clock_name [lindex $node 1]]
            if {![dict exists $result $key] || \
                ($delay_type eq "max" && $arrival > [dict get $result $key]) || \
                ($delay_type eq "min" && $arrival < [dict get $result $key])} {
                dict set result $key $arrival
            }
        } elseif {$depth < 4 && $length > 0} {
            foreach child $node {
                if {$child ne $node} {lappend pending [list $child [expr {$depth+1}]]}
            }
        }
    }
    return $result
}

proc ::cg_latency::delta {source sink delay_type scale_ns} {
    if {[dict size $source] == 0} {return [dict create status missing_input_window]}
    if {[dict size $sink] == 0} {return [dict create status missing_sink_window]}
    set best {}
    set chosen {}
    dict for {key sink_arrival} $sink {
        if {![dict exists $source $key]} {continue}
        set input_arrival [dict get $source $key]
        set value [expr {($sink_arrival-$input_arrival)*$scale_ns}]
        if {$best eq {} || ($delay_type eq "max" && $value > $best) || \
            ($delay_type eq "min" && $value < $best)} {
            set best $value
            set chosen [dict create clock [lindex $key 0] source_edge [lindex $key 1] \
                input_arrival_ns [expr {$input_arrival*$scale_ns}] \
                sink_arrival_ns [expr {$sink_arrival*$scale_ns}] latency_ns $value]
        }
    }
    if {$best eq {}} {return [dict create status no_common_clock_edge]}
    # Negative envelope differences can occur after reconvergence. Do not turn them into 0.
    if {$best < -1.0e-9} {dict set chosen status negative_delta; return $chosen}
    if {$best < 0} {dict set chosen latency_ns 0.0}
    dict set chosen status ok
    return $chosen
}

proc ::cg_latency::time_scale {design options} {
    set requested [dict get $options -time_unit_ns]
    if {$requested ne "auto"} {return $requested}
    set seconds [attr $design time_unit_in_second]
    if {[finite $seconds] && $seconds > 0} {return [expr {$seconds*1.0e9}]}
    set units {}
    foreach_in_collection lib [get_libs -quiet *] {
        set value [attr $lib time_unit_in_second]
        if {[finite $value] && $value > 0} {lappend units [expr {double($value)}]}
    }
    set units [lsort -unique -real $units]
    if {[llength $units] == 1} {return [expr {[lindex $units 0]*1.0e9}]}
    error "Cannot determine the design time unit unambiguously; verify the current design/library time units."
}

proc ::cg_latency::transform {family n} {
    switch -- $family {
        constant {return 0.0}
        log10 {return [expr {log10(double($n))}]}
        sqrt {return [expr {sqrt(double($n))}]}
        linear {return [expr {double($n)}]}
        default {error "Unknown model family: $family"}
    }
}

proc ::cg_latency::model_value {model n} {
    set x [transform [dict get $model family] $n]
    expr {max(0.0, [dict get $model a]+[dict get $model b]*$x)}
}
# OLS with centered sums; analytic leave-one-observation-out CV via leverage.

proc ::cg_latency::fit_candidate {pairs family} {
    set n [llength $pairs]
    set xs {}; set ys {}; set mx 0.0; set my 0.0; set i 0
    foreach pair $pairs {
        lassign $pair loads y
        set x [transform $family $loads]
        lappend xs $x; lappend ys $y
        incr i
        set mx [expr {$mx+($x-$mx)/$i}]
        set my [expr {$my+($y-$my)/$i}]
    }
    set sxx 0.0; set sxy 0.0; set syy 0.0
    foreach x $xs y $ys {
        set dx [expr {$x-$mx}]; set dy [expr {$y-$my}]
        set sxx [expr {$sxx+$dx*$dx}]
        set sxy [expr {$sxy+$dx*$dy}]
        set syy [expr {$syy+$dy*$dy}]
    }
    if {$family eq "constant"} {
        set b 0.0
    } else {
        if {$sxx <= 1.0e-24} {return {}}
        set b [expr {$sxy/$sxx}]
    }
    set a [expr {$my-$b*$mx}]
    set model [dict create family $family a $a b $b]
    set sse 0.0; set cv_sse 0.0
    foreach x $xs y $ys {
        set raw_prediction [expr {$a+$b*$x}]
        set residual [expr {$y-$raw_prediction}]
        set error [expr {$y-max(0.0,$raw_prediction)}]
        set sse [expr {$sse+$error*$error}]
        set h [expr {1.0/$n}]
        if {$family ne "constant"} {set h [expr {$h+($x-$mx)*($x-$mx)/$sxx}]}
        if {$h >= 1.0-1.0e-10} {return {}}
        set loo_prediction [expr {max(0.0,$y-$residual/(1.0-$h))}]
        set cv_error [expr {$y-$loo_prediction}]
        set cv_sse [expr {$cv_sse+$cv_error*$cv_error}]
    }
    dict set model rmse_ns [expr {sqrt($sse/$n)}]
    dict set model loo_rmse_ns [expr {sqrt($cv_sse/$n)}]
    dict set model r2 [expr {$syy > 1.0e-24 ? 1.0-$sse/$syy : ($sse < 1.0e-24 ? 1.0 : 0.0)}]
    return $model
}

proc ::cg_latency::fit_models {pairs} {
    set distinct {}; set counts {}
    foreach pair $pairs {lappend distinct [lindex $pair 0]; lappend counts [lindex $pair 0]}
    set n [llength $pairs]
    if {$n < 5 || [llength [lsort -unique -integer $distinct]] < 3} {
        return [dict create status insufficient_samples samples $n candidates {} model {}]
    }
    set candidates {}; set best {}
    foreach family {constant log10 sqrt linear} {
        set model [fit_candidate $pairs $family]
        if {$model eq {}} {continue}
        lappend candidates $model
        if {$best eq {} || [dict get $model loo_rmse_ns] < [dict get $best loo_rmse_ns]} {set best $model}
    }
    if {$best eq {}} {return [dict create status degenerate_data samples $n candidates {} model {}]}
    set counts [lsort -integer $counts]
    dict set best n_min [lindex $counts 0]
    dict set best n_max [lindex $counts end]
    dict set best samples $n
    dict set best unit ns
    return [dict create status ok samples $n candidates $candidates model $best]
}

proc ::cg_latency::bin_bounds {n} {
    # 1-2-5 sequence: [1000,2000), [2000,5000), [5000,10000), ...
    set base 1
    while {$n >= 10*$base} {set base [expr {10*$base}]}
    if {$n < 2*$base} {return [list $base [expr {2*$base}]]}
    if {$n < 5*$base} {return [list [expr {2*$base}] [expr {5*$base}]]}
    return [list [expr {5*$base}] [expr {10*$base}]]
}

proc ::cg_latency::message {text} {
    puts "CG_LATENCY: $text"
    flush stdout
}
proc ::cg_latency::number {value} {
    if {$value eq {}} {return NA}
    return [format %.4f $value]
}
proc ::cg_latency::options {args} {
    set o [dict create -max_level 3 -out_dir {} -delay_type max -time_unit_ns auto]
    if {[llength $args] % 2} {error "Use -max_level N -out_dir directory -delay_type max|min"}
    foreach {key value} $args {
        if {$key ni {-max_level -out_dir -delay_type}} {error "Unknown option $key; use -max_level, -out_dir, -delay_type"}
        dict set o $key $value
    }
    set level [dict get $o -max_level]
    if {![string is integer -strict $level] || ($level != 0 && $level < 2)} {
        error "-max_level must be >= 2, or 0 for all sub-block levels (TOP=1)"
    }
    if {[dict get $o -delay_type] ni {max min}} {error "-delay_type must be max or min"}
    if {[dict get $o -out_dir] eq {}} {
        set stem [file join [pwd] "cg_latency_[clock seconds]_[pid]"]
        set directory $stem
        set i 0
        while {[file exists $directory]} {incr i; set directory "${stem}_$i"}
        dict set o -out_dir $directory
    }
    return $o
}
proc ::cg_latency::block_list {options} {
    set by_path {}
    set max_level [dict get $options -max_level]
    foreach_in_collection block [get_cells -quiet -hierarchical -filter {is_hierarchical == true} *] {
        set path [get_object_name $block]
        set level [expr {[llength [split $path /]]+1}]
        if {$max_level != 0 && $level > $max_level} {continue}
        if {[truth [attr $block is_black_box false]]} {continue}
        dict set by_path $path [dict create path $path level $level obj $block]
    }
    set blocks {}
    foreach path [lsort -dictionary [dict keys $by_path]] {lappend blocks [dict get $by_path $path]}
    return $blocks
}
proc ::cg_latency::sink_index {} {
    # Clock-pin identities only: no per-cell chip-wide attribute queries here.
    set result {}
    foreach {kind flag} {DFF -edge_triggered LATCH -level_sensitive} {
        set pins [all_registers $flag -clock_pins]
        set names [get_object_name $pins]
        set count [sizeof_collection $pins]
        set bulk 0
        if {![catch {llength $names} n] && $n == $count} {set bulk 1}
        if {!$bulk} {
            set names {}
            foreach_in_collection pin $pins {lappend names [get_object_name $pin]}
        }
        foreach name $names {
            set slash [string last / $name]
            if {$slash < 0} {continue}
            dict set result $name $kind
        }
    }
    return $result
}
proc ::cg_latency::eligible_sink {meta} {
    variable cell_cache
    set name [dict get $meta cell]
    if {![dict exists $cell_cache $name]} {
        set cell [get_cells -quiet -of_objects [dict get $meta obj]]
        set included [expr {[sizeof_collection $cell] == 1}]
        if {$included} {
            foreach flag {is_hierarchical is_black_box is_memory_cell is_integrated_clock_gating_cell} {
                if {[truth [attr $cell $flag false]]} {set included 0; break}
            }
        }
        dict set cell_cache $name $included
    }
    return [dict get $cell_cache $name]
}
proc ::cg_latency::window {obj name mode} {
    variable windows_cache
    if {![dict exists $windows_cache $name]} {
        dict set windows_cache $name [parse_windows [attr $obj arrival_window] $mode {*}]
    }
    return [dict get $windows_cache $name]
}
proc ::cg_latency::collect {blocks sinks mode scale} {
    set rows {}
    foreach block $blocks {
        set path [dict get $block path]
        set inputs {}
        # Only the current block's interface input/inout pins with clocks assigned.
        # No TOP ports, name guessing, internal-pin enumeration, or non-clock output.
        foreach_in_collection pin [get_pins -quiet -of_objects [dict get $block obj] \
                -filter {direction == in || direction == inout}] {
            set clocks [attr $pin clocks]
            if {$clocks eq {} || [sizeof_collection $clocks] == 0} {continue}
            dict set inputs [get_object_name $pin] [list $pin $clocks]
        }
        foreach input_name [lsort -dictionary [dict keys $inputs]] {
            lassign [dict get $inputs $input_name] input clocks
            set started [clock milliseconds]
            message "$input_name START"
            set source [window $input $input_name $mode]
            set fanout [all_fanout -flat -endpoints_only -trace_arcs timing \
                -continue_trace generated_clock_source -from $input]
            set names [get_object_name $fanout]
            set bulk 0
            if {![catch {llength $names} n] && $n == [sizeof_collection $fanout]} {set bulk 1}
            set i 0
            set cells {}
            foreach_in_collection pin $fanout {
                if {$bulk} {set name [lindex $names $i]} else {set name [get_object_name $pin]}
                incr i
                if {![dict exists $sinks $name]} {continue}
                set cell [string range $name 0 [expr {[string last / $name]-1}]]
                if {[string first "$path/" $cell] != 0} {continue}
                set meta [dict create obj $pin kind [dict get $sinks $name] cell $cell]
                if {![eligible_sink $meta]} {continue}
                dict set cells $cell $name $meta
            }
            set values {}; set dffs 0; set latches 0; set missing 0
            dict for {cell pins} $cells {
                set best {}; set failed 0; set kind {}
                dict for {name meta} $pins {
                    set kind [dict get $meta kind]
                    set measurement [delta $source [window [dict get $meta obj] $name $mode] $mode $scale]
                    if {[dict get $measurement status] ne "ok"} {set failed 1; continue}
                    set value [dict get $measurement latency_ns]
                    if {$best eq {} || ($mode eq "max" && $value > $best) || \
                        ($mode eq "min" && $value < $best)} {set best $value}
                }
                if {$kind eq "DFF"} {incr dffs} else {incr latches}
                if {$failed || $best eq {}} {incr missing} else {lappend values $best}
            }
            set bounds [fence $values 1.5 8]
            set retained {}; set outliers 0
            foreach value $values {
                if {[inside $value $bounds]} {lappend retained $value} else {incr outliers}
            }
            set propagated 1
            foreach_in_collection clk $clocks {
                if {![truth [attr $clk is_propagated false]]} {set propagated 0}
            }
            set stats [summary $retained]
            set total [expr {$dffs+$latches}]
            set eligible [expr {$total > 0 && $missing == 0 && [llength $retained] > 0 && $propagated}]
            lappend rows [dict merge [dict create path $path level [dict get $block level] \
                input $input_name dff $dffs latch $latches loads $total missing $missing \
                outliers $outliers propagated $propagated eligible $eligible] $stats]
            message "$input_name DONE: DFF=$dffs, latch=$latches, median=[number [dict get $stats median]] ns ([expr {([clock milliseconds]-$started)/1000.0}] s)"
        }
    }
    return $rows
}
proc ::cg_latency::write_reports {design blocks rows options} {
    set by_path {}; set visible {}; set pairs {}; set bins {}; set excluded 0
    foreach row $rows {
        set path [dict get $row path]
        dict lappend by_path $path $row
        set ancestor $path
        while {$ancestor ne {}} {
            dict set visible $ancestor 1
            set slash [string last / $ancestor]
            if {$slash < 0} {break}
            set ancestor [string range $ancestor 0 [expr {$slash-1}]]
        }
        if {![dict get $row eligible]} {incr excluded; continue}
        set n [dict get $row loads]
        lappend pairs [list $n [dict get $row median]]
        lassign [bin_bounds $n] low high
        dict lappend bins $low [dict get $row median]
    }
    set directory [dict get $options -out_dir]
    set hierarchy [file join $directory hierarchy.rpt]
    set estimate [file join $directory estimated_latency.rpt]
    set ch [open $hierarchy w]
    set code [catch {
        fconfigure $ch -encoding utf-8 -translation lf
        puts $ch "Clock latency analysis v2.0; units: ns; [dict get $options -delay_type]"
        puts $ch "TOP=level 1; analyze sub-block levels 2..[dict get $options -max_level] (0=all)."
        puts $ch "Mean/median exclude latency outliers; DFF/latch counts include all reachable cells."
        puts $ch {}
        puts $ch [get_object_name $design]
        foreach block $blocks {
            set path [dict get $block path]
            if {![dict exists $visible $path]} {continue}
            set indent [string repeat {  } [expr {[dict get $block level]-1}]]
            puts $ch "$indent[file tail $path] (level [dict get $block level])"
            if {![dict exists $by_path $path]} {continue}
            foreach row [dict get $by_path $path] {
                set line [format {%s  (%s, DFF: %d, Latch: %d, Average latency: %s ns, Median latency: %s ns)} \
                    $indent [file tail [dict get $row input]] [dict get $row dff] [dict get $row latch] \
                    [number [dict get $row mean]] [number [dict get $row median]]]
                if {[dict get $row missing]} {append line "; missing latency: [dict get $row missing] (excluded from formula)"}
                if {[dict get $row outliers]} {append line "; removed outliers: [dict get $row outliers]"}
                if {![dict get $row propagated]} {append line {; ideal/unknown clock (excluded from formula)}}
                puts $ch $line
            }
        }
        if {![llength $rows]} {puts $ch {  No sub-block interface inputs with a clocks attribute were found.}}
    } result error_options]
    close $ch
    if {$code} {return -options $error_options $result}
    set fit [fit_models $pairs]
    set ch [open $estimate w]
    set code [catch {
        fconfigure $ch -encoding utf-8 -translation lf
        puts $ch {Clock latency estimate (ns); N = DFF + latch cells}
        puts $ch {Fanout range          Estimated latency (median)    Observations}
        foreach low [lsort -integer [dict keys $bins]] {
            lassign [bin_bounds $low] lo hi
            set values [dict get $bins $low]
            puts $ch [format {%-21s %-29s %d} "$lo..[expr {$hi-1}]" \
                [number [dict get [summary $values] median]] [llength $values]]
        }
        puts $ch {}
        set model [dict get $fit model]
        if {$model eq {}} {
            puts $ch "Formula: insufficient data ([llength $pairs] usable observations; need >=5 and >=3 fanout sizes)."
        } else {
            set term 0
            switch -- [dict get $model family] {
                log10 {set term {log10(N)}}
                sqrt {set term {sqrt(N)}}
                linear {set term N}
            }
            puts $ch [format {Estimated latency (ns) = max(0, %.8g + %.8g * %s)} \
                [dict get $model a] [dict get $model b] $term]
            puts $ch "Reference N range: [dict get $model n_min]..[dict get $model n_max]; observations: [llength $pairs]"
        }
        if {$excluded} {puts $ch "Excluded from estimate: $excluded observations with no valid latency, incomplete arrivals, or ideal clocks."}
        puts $ch {All parent/child and shared-load observations are retained; new-IC accuracy requires actual validation.}
    } result error_options]
    close $ch
    if {$code} {return -options $error_options $result}
    return [list $hierarchy $estimate]
}
proc ::cg_latency::run {args} {
    variable windows_cache
    variable cell_cache
    set options [eval [linsert $args 0 ::cg_latency::options]]
    foreach command {current_design current_instance get_attribute get_cells get_pins \
        all_clocks all_registers all_fanout get_object_name sizeof_collection \
        foreach_in_collection get_app_var set_app_var update_timing} {
        if {![llength [info commands ::$command]]} {error "PrimeTime command unavailable: $command; run inside pt_shell."}
    }
    set design [current_design]
    if {$design eq {} || [sizeof_collection $design] != 1} {error "A single current_design is required."}
    if {[sizeof_collection [all_clocks]] == 0} {error "No clocks are defined."}
    set directory [file normalize [dict get $options -out_dir]]
    dict set options -out_dir $directory
    file mkdir $directory
    set old_instance [current_instance .]
    set old_save [get_app_var timing_save_pin_arrival_and_slack]
    set windows_cache {}; set cell_cache {}
    set code [catch {
        current_instance
        message "v2.0: sub-blocks only; preparing timing"
        set_app_var timing_save_pin_arrival_and_slack true
        update_timing
        set scale [time_scale $design $options]
        set blocks [block_list $options]
        message {indexing DFF/latch clock-pin names}
        set sinks [sink_index]
        set rows [collect $blocks $sinks [dict get $options -delay_type] $scale]
        set reports [write_reports $design $blocks $rows $options]
    } result error_options]
    set windows_cache {}; set cell_cache {}
    set cleanup_errors {}
    if {[catch {set_app_var timing_save_pin_arrival_and_slack $old_save} message]} {lappend cleanup_errors $message}
    if {[catch {
        current_instance
        if {$old_instance ne {}} {current_instance $old_instance}
    } message]} {lappend cleanup_errors $message}
    if {$code} {return -options $error_options $result}
    if {[llength $cleanup_errors]} {error "State restoration failed: $cleanup_errors"}
    message "DONE: [join $reports {; }]"
    return $reports
}
