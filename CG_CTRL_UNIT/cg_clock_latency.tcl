# Clock latency versus sequential-load count, for an already loaded PrimeTime design.
# Tcl 8.5+. Sourcing this file only defines commands; it does not run analysis.
# Quick start: ::cg_latency::run -max_level 3 -out_dir ./cg_latency_results
namespace eval ::cg_latency {
    variable version 1.0
    variable windows_cache {}
    variable warnings {}
    variable channels {}
    variable last_model {}
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
proc ::cg_latency::warn {message} {
    variable warnings
    if {[lsearch -exact $warnings $message] < 0} {
        lappend warnings $message
        puts stderr "CG_LATENCY: $message"
    }
}
proc ::cg_latency::csv {values} {
    set result {}
    foreach value $values {
        lappend result "\"[string map [list \" \"\"] $value]\""
    }
    return [join $result ,]
}
proc ::cg_latency::open_output {directory name} {
    variable channels
    set ch [open [file join $directory $name] w]
    fconfigure $ch -encoding utf-8 -translation lf
    lappend channels $ch
    return $ch
}
proc ::cg_latency::close_outputs {} {
    variable channels
    foreach ch $channels {catch {close $ch}}
    set channels {}
}
proc ::cg_latency::number {x} {
    if {$x eq {}} {return NA}
    return [format %.6f $x]
}

# Linear-interpolated sample quantile (index = (n-1)*p).
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
proc ::cg_latency::window {obj options} {
    variable windows_cache
    set name [get_object_name $obj]
    set key [list [attr $obj object_class] $name]
    if {![dict exists $windows_cache $key]} {
        dict set windows_cache $key [parse_windows [attr $obj arrival_window] \
            [dict get $options -delay_type] [dict get $options -clock_patterns]]
    }
    return [dict get $windows_cache $key]
}

# This is an arrival-envelope difference, not a constrained point-to-point path query.
# Source-edge identity handles inverter polarity without subtracting unrelated clocks.
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

proc ::cg_latency::clock_names {obj patterns} {
    set clocks [attr $obj clocks]
    if {$clocks eq {}} {return {}}
    set names [get_object_name $clocks]
    set result {}
    foreach name $names {if {[matches $name $patterns]} {lappend result $name}}
    return [lsort -unique $result]
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
    error "Cannot determine the design time unit unambiguously. Use -time_unit_ns (1 for ns, 0.001 for ps)."
}
proc ::cg_latency::sink_index {options} {
    set result {}
    foreach {kind flag} {DFF -edge_triggered LATCH -level_sensitive} {
        set pins [all_registers $flag -clock_pins]
        foreach_in_collection pin $pins {
            set cell [get_cells -quiet -of_objects $pin]
            if {[sizeof_collection $cell] != 1} {continue}
            set cell_name [get_object_name $cell]
            set ref [attr $cell ref_name]
            if {[matches $cell_name [dict get $options -exclude_cell_patterns]] || \
                [matches $ref [dict get $options -exclude_ref_patterns]]} {continue}
            if {[truth [attr $cell is_hierarchical false]] || \
                [truth [attr $cell is_black_box false]] || \
                [truth [attr $cell is_memory_cell false]] || \
                [truth [attr $cell is_integrated_clock_gating_cell false]]} {continue}
            dict set result [get_object_name $pin] [dict create \
                obj $pin cell $cell_name ref $ref kind $kind]
        }
    }
    return $result
}
proc ::cg_latency::block_list {options} {
    set result [list [dict create path {} level 1 obj {}]]
    set blocks [get_cells -quiet -hierarchical -filter {is_hierarchical == true} *]
    set by_path {}
    foreach_in_collection block $blocks {
        set path [get_object_name $block]
        if {[truth [attr $block is_black_box false]] || \
            [matches $path [dict get $options -exclude_cell_patterns]]} {continue}
        set level [expr {[llength [split $path /]]+1}]
        if {[dict get $options -max_level] != 0 && $level > [dict get $options -max_level]} {continue}
        dict set by_path $path [dict create path $path level $level obj $block]
    }
    foreach path [lsort -dictionary [dict keys $by_path]] {lappend result [dict get $by_path $path]}
    return $result
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
proc ::cg_latency::predict {loads {allow_extrapolation 0}} {
    variable last_model
    if {$last_model eq {}} {error "No fitted model. Run analysis with sufficient eligible observations first."}
    if {![string is integer -strict $loads] || $loads < 1} {error "loads must be a positive integer"}
    set outside [expr {$loads < [dict get $last_model n_min] || $loads > [dict get $last_model n_max]}]
    if {$outside && !$allow_extrapolation} {error "Outside calibration range; pass a second argument of 1 to allow extrapolation."}
    return [dict create loads $loads estimated_latency_ns [model_value $last_model $loads] extrapolated $outside]
}
proc ::cg_latency::bin_bounds {n} {
    # 1-2-5 sequence: [1000,2000), [2000,5000), [5000,10000), ...
    set base 1
    while {$n >= 10*$base} {set base [expr {10*$base}]}
    if {$n < 2*$base} {return [list $base [expr {2*$base}]]}
    if {$n < 5*$base} {return [list [expr {2*$base}] [expr {5*$base}]]}
    return [list [expr {5*$base}] [expr {10*$base}]]
}

proc ::cg_latency::options {args} {
    set o [dict create -max_level 3 -out_dir {} -delay_type max -iqr_multiplier 1.5 \
        -outlier_min_samples 8 -clock_patterns {*} -exclude_ref_patterns {} \
        -exclude_cell_patterns {} -min_coverage 1.0 -time_unit_ns auto \
        -write_loads 1 -overwrite 0 -continue_generated 1]
    if {[llength $args] % 2} {error "Options require name/value pairs. See cg_clock_latency_README.md."}
    foreach {key value} $args {
        if {![dict exists $o $key]} {error "Unknown option: $key"}
        dict set o $key $value
    }
    foreach key {-max_level -outlier_min_samples} {
        set v [dict get $o $key]
        if {![string is integer -strict $v] || $v < 0} {error "$key must be a nonnegative integer"}
    }
    if {[dict get $o -outlier_min_samples] < 4} {error "-outlier_min_samples must be >= 4"}
    foreach key {-write_loads -overwrite -continue_generated} {
        if {[dict get $o $key] ni {0 1}} {error "$key must be 0 or 1"}
    }
    foreach key {-iqr_multiplier -min_coverage} {
        set v [dict get $o $key]
        if {![finite $v] || $v < 0} {error "$key must be a finite nonnegative number"}
    }
    if {[dict get $o -min_coverage] > 1} {error "-min_coverage must be <= 1"}
    if {[dict get $o -delay_type] ni {max min}} {error "-delay_type must be max or min"}
    set v [dict get $o -time_unit_ns]
    if {$v ne "auto" && (![finite $v] || $v <= 0)} {error "-time_unit_ns must be auto or a positive number"}
    foreach key {-clock_patterns -exclude_ref_patterns -exclude_cell_patterns} {
        if {[catch {llength [dict get $o $key]}]} {error "$key must be a Tcl list of glob patterns"}
    }
    if {[dict get $o -out_dir] eq {}} {
        set stem [file join [pwd] "cg_latency_[clock seconds]_[pid]"]
        set candidate $stem
        set serial 0
        while {[file exists $candidate]} {incr serial; set candidate "${stem}_$serial"}
        dict set o -out_dir $candidate
    }
    return $o
}

proc ::cg_latency::collect {design blocks sinks options scale} {
    set rows {}
    set load_ch {}
    if {[dict get $options -write_loads]} {
        set load_ch [open_output [dict get $options -out_dir] loads.csv]
        puts $load_ch [csv {block level clock_input cell kind connected_clock_pins selected_clock_pin clock source_edge input_arrival_ns sink_arrival_ns latency_ns status detail}]
    }
    set mode [dict get $options -delay_type]
    foreach block $blocks {
        set path [dict get $block path]
        set label $path
        if {$path eq {}} {
            set label [get_object_name $design]
            set inputs [get_ports -quiet -filter {direction == in || direction == inout} *]
        } else {
            set inputs [get_pins -quiet -of_objects [dict get $block obj] \
                -filter {direction == in || direction == inout}]
        }
        set input_map {}
        foreach_in_collection input $inputs {
            set names [clock_names $input [dict get $options -clock_patterns]]
            if {[llength $names]} {dict set input_map [get_object_name $input] [list $input $names]}
        }
        puts "CG_LATENCY: level [dict get $block level], $label, [dict size $input_map] clock input(s)"
        foreach input_name [lsort -dictionary [dict keys $input_map]] {
            lassign [dict get $input_map $input_name] input names
            set source_window [window $input $options]
            set fanout_cmd [list all_fanout -flat -endpoints_only -trace_arcs timing -from $input]
            if {[dict get $options -continue_generated]} {lappend fanout_cmd -continue_trace generated_clock_source}
            set fanout [eval $fanout_cmd]
            set cells {}
            foreach_in_collection pin $fanout {
                set pin_name [get_object_name $pin]
                if {![dict exists $sinks $pin_name]} {continue}
                set meta [dict get $sinks $pin_name]
                set cell_name [dict get $meta cell]
                # Keep only descendants of this block. Flat fanout may leave/re-enter blocks.
                if {$path ne {} && [string first "$path/" $cell_name] != 0} {continue}
                dict set cells $cell_name $pin_name $meta
            }
            set records {}; set values {}; set dffs 0; set latches 0; set missing 0
            foreach cell_name [lsort -dictionary [dict keys $cells]] {
                set pin_map [dict get $cells $cell_name]
                set best {}; set failures {}; set kind {}
                dict for {pin_name meta} $pin_map {
                    set kind [dict get $meta kind]
                    set measurement [delta $source_window [window [dict get $meta obj] $options] $mode $scale]
                    if {[dict get $measurement status] ne "ok"} {
                        lappend failures "$pin_name:[dict get $measurement status]"
                        continue
                    }
                    dict set measurement selected_pin $pin_name
                    if {$best eq {} || \
                        ($mode eq "max" && [dict get $measurement latency_ns] > [dict get $best latency_ns]) || \
                        ($mode eq "min" && [dict get $measurement latency_ns] < [dict get $best latency_ns])} {set best $measurement}
                }
                if {$kind eq "DFF"} {incr dffs} else {incr latches}
                set rec [dict create cell $cell_name kind $kind pins [lsort -dictionary [dict keys $pin_map]]]
                if {[llength $failures] || $best eq {}} {
                    dict set rec status missing
                    dict set rec detail [join $failures {; }]
                    incr missing
                } else {
                    set rec [dict merge $rec $best]
                    dict set rec detail {}
                    lappend values [dict get $rec latency_ns]
                }
                lappend records $rec
            }
            set bounds [fence $values [dict get $options -iqr_multiplier] [dict get $options -outlier_min_samples]]
            set retained {}; set outliers 0
            foreach rec $records {
                if {[dict get $rec status] eq "ok"} {
                    if {[inside [dict get $rec latency_ns] $bounds]} {
                        lappend retained [dict get $rec latency_ns]
                    } else {dict set rec status outlier; incr outliers}
                }
                if {$load_ch ne {}} {
                    set line [list $label [dict get $block level] $input_name [dict get $rec cell] \
                        [dict get $rec kind] [join [dict get $rec pins] {;}]]
                    foreach key {selected_pin clock source_edge input_arrival_ns sink_arrival_ns latency_ns} {
                        if {[dict exists $rec $key]} {lappend line [dict get $rec $key]} else {lappend line {}}
                    }
                    lappend line [dict get $rec status] [dict get $rec detail]
                    puts $load_ch [csv $line]
                }
            }
            set total [expr {$dffs+$latches}]
            set measured [llength $values]
            set coverage [expr {$total > 0 ? double($measured)/$total : 0.0}]
            set propagated 1
            foreach name $names {
                if {![truth [attr [get_clocks -quiet [list $name]] is_propagated false]]} {set propagated 0}
            }
            set stats [summary $retained]
            set eligible 1; set reason included
            if {$total == 0} {set eligible 0; set reason no_loads
            } elseif {![llength $retained]} {set eligible 0; set reason no_valid_latency
            } elseif {!$propagated} {set eligible 0; set reason ideal_clock
            } elseif {$coverage < [dict get $options -min_coverage]} {set eligible 0; set reason incomplete_coverage}
            if {$missing} {
                set advice {inspect loads.csv}
                if {![dict get $options -write_loads]} {set advice {rerun with -write_loads 1 for details}}
                warn "$label / $input_name: $missing of $total loads have unavailable or invalid arrivals; $advice."
            }
            if {!$propagated} {warn "$label / $input_name: includes an ideal/unknown-propagation clock; excluded from model."}
            set row [dict merge [dict create block $label path $path level [dict get $block level] \
                clock_input $input_name clocks [join $names {;}] dff_count $dffs latch_count $latches \
                sequential_loads $total measured_loads $measured missing_loads $missing \
                outlier_loads $outliers retained_loads [llength $retained] coverage $coverage \
                outlier_rule [dict get $bounds reason] fit_eligible $eligible fit_reason $reason] $stats]
            lappend rows $row
        }
    }
    return $rows
}

proc ::cg_latency::write_reports {design blocks rows options scale} {
    variable version
    variable warnings
    variable last_model
    set directory [dict get $options -out_dir]
    set columns {block level clock_input clocks dff_count latch_count sequential_loads measured_loads missing_loads outlier_loads retained_loads coverage outlier_rule mean median p10 p90 min max fit_eligible fit_reason}
    set ch [open_output $directory observations.csv]
    puts $ch [csv $columns]
    set pairs {}; set bins {}; set rows_by_path {}
    foreach row $rows {
        set fields {}
        foreach column $columns {lappend fields [dict get $row $column]}
        puts $ch [csv $fields]
        dict lappend rows_by_path [dict get $row path] $row
        if {![dict get $row fit_eligible]} {continue}
        set n [dict get $row sequential_loads]
        set y [dict get $row median]
        lappend pairs [list $n $y]
        lassign [bin_bounds $n] low high
        dict lappend bins $low $row
    }
    set fit [fit_models $pairs]
    set last_model [dict get $fit model]
    if {$last_model ne {}} {
        dict set last_model source_design [get_object_name $design]
        dict set last_model delay_type [dict get $options -delay_type]
        dict set last_model estimator arrival_envelope_difference
    }
    set ch [open_output $directory hierarchy.rpt]
    puts $ch "Clock latency analysis v$version; design: [get_object_name $design]"
    puts $ch "All latency fields are ns. delay_type=[dict get $options -delay_type]; 1 design unit=$scale ns."
    puts $ch "TOP=level 1; max_level=[dict get $options -max_level] (0=all). All scanned parent/child observations retained."
    puts $ch "N=DFF cells+latch cells (not bits); count includes loads with missing/outlier latency."
    puts $ch "Latency=matched-clock/source-edge arrival-envelope difference; rise/fall collapsed per source edge."
    puts $ch "Coverage=measured loads / N before IQR filtering. Statistics use retained loads only."
    puts $ch {}
    foreach block $blocks {
        set path [dict get $block path]
        set label [file tail $path]
        if {$path eq {}} {set label [get_object_name $design]}
        set indent [string repeat {  } [expr {[dict get $block level]-1}]]
        puts $ch "$indent$label (level [dict get $block level])"
        if {![dict exists $rows_by_path $path]} {puts $ch "$indent  (no recognized clock inputs)"; continue}
        foreach row [dict get $rows_by_path $path] {
            puts $ch [format {%s  %s: N=%d (DFF=%d latch=%d), mean=%s ns, median=%s ns, P10=%s ns, P90=%s ns; measured=%d retained=%d outlier=%d missing=%d; fit=%s} \
                $indent [dict get $row clock_input] [dict get $row sequential_loads] \
                [dict get $row dff_count] [dict get $row latch_count] \
                [number [dict get $row mean]] [number [dict get $row median]] \
                [number [dict get $row p10]] [number [dict get $row p90]] \
                [dict get $row measured_loads] [dict get $row retained_loads] \
                [dict get $row outlier_loads] [dict get $row missing_loads] [dict get $row fit_reason]]
        }
    }
    set ch [open_output $directory fanout_latency.csv]
    puts $ch [csv {loads_from_inclusive loads_to_exclusive observations median_actual_loads empirical_median_ns empirical_mean_ns empirical_p10_ns empirical_p90_ns formula_at_median_loads_ns}]
    foreach low [lsort -integer [dict keys $bins]] {
        set ns {}; set counts {}
        foreach row [dict get $bins $low] {lappend ns [dict get $row median]; lappend counts [dict get $row sequential_loads]}
        set s [summary $ns]; set c [summary $counts]
        set predicted {}
        if {$last_model ne {}} {set predicted [model_value $last_model [dict get $c median]]}
        lassign [bin_bounds $low] lo hi
        puts $ch [csv [list $lo $hi [llength $ns] [dict get $c median] [dict get $s median] \
            [dict get $s mean] [dict get $s p10] [dict get $s p90] $predicted]]
    }
    set ch [open_output $directory model.rpt]
    puts $ch "Model status: [dict get $fit status]; eligible observations: [llength $pairs]"
    puts $ch "One observation=(block,clock_input); target=retained-load median latency (ns); N=total unique sequential cells."
    puts $ch "Parent/child and multiple-input observations all retained with equal weight."
    puts $ch "Candidates: max(0,a+b*log10(N)), max(0,a+b*sqrt(N)), max(0,a+b*N), constant baseline."
    puts $ch "Selection: lowest leave-one-observation-out RMSE; this is NOT independent-chip validation."
    puts $ch "Nested/shared-load observations are correlated. Cross-IC accuracy is unknown until separately validated."
    puts $ch "No candidate is required to increase with fanout. No formula if <5 observations or <3 distinct N."
    puts $ch {}
    foreach candidate [dict get $fit candidates] {
        puts $ch [format {%s: a=%.12g b=%.12g train_RMSE_ns=%.6g LOO_RMSE_ns=%.6g R2=%.6g} \
            [dict get $candidate family] [dict get $candidate a] [dict get $candidate b] \
            [dict get $candidate rmse_ns] [dict get $candidate loo_rmse_ns] [dict get $candidate r2]]
    }
    if {$last_model ne {}} {
        puts $ch "\nSelected: [dict get $last_model family]; N range=[dict get $last_model n_min]..[dict get $last_model n_max]"
        set expression N
        switch -- [dict get $last_model family] {
            log10 {set expression {log10(N)}}
            sqrt {set expression {sqrt(N)}}
            constant {set expression 0}
        }
        puts $ch [format {Estimated latency (ns) = max(0, %.12g + %.12g * %s)} \
            [dict get $last_model a] [dict get $last_model b] $expression]
    }
    set ch [open_output $directory model.tcl]
    puts $ch {# Reusable calibration; source with cg_clock_latency.tcl, even outside PrimeTime.}
    puts $ch {namespace eval ::cg_latency {variable last_model}}
    puts $ch [list set ::cg_latency::last_model $last_model]
    set ch [open_output $directory estimates.csv]
    puts $ch [csv {sequential_loads estimated_latency_ns extrapolated}]
    if {$last_model ne {}} {
        set base 1
        while {$base <= [dict get $last_model n_max]} {
            foreach factor {1 2 5} {
                set n [expr {$base*$factor}]
                if {$n < [dict get $last_model n_min] || $n > [dict get $last_model n_max]} {continue}
                puts $ch [csv [list $n [model_value $last_model $n] 0]]
            }
            set base [expr {$base*10}]
        }
    }
    set ch [open_output $directory run.log]
    puts $ch "status=COMPLETE"
    puts $ch "options=$options"
    puts $ch "observations=[llength $rows]; model_status=[dict get $fit status]"
    foreach message $warnings {puts $ch "WARNING: $message"}
    return [dict create out_dir $directory observations [llength $rows] \
        model_status [dict get $fit status] model $last_model]
}

proc ::cg_latency::run {args} {
    variable windows_cache
    variable warnings
    variable last_model
    set options [eval [linsert $args 0 ::cg_latency::options]]
    foreach command {current_design current_instance get_attribute get_cells get_pins get_ports \
        get_clocks all_clocks all_registers all_fanout get_object_name sizeof_collection \
        foreach_in_collection get_app_var set_app_var update_timing} {
        if {![llength [info commands ::$command]]} {error "PrimeTime command unavailable: $command. Run inside pt_shell with a loaded design."}
    }
    set design [current_design]
    if {$design eq {} || [sizeof_collection $design] != 1} {error "A single current_design is required."}
    if {[sizeof_collection [all_clocks]] == 0} {error "No clocks are defined in current_design."}
    set directory [file normalize [dict get $options -out_dir]]
    dict set options -out_dir $directory
    set output_names {hierarchy.rpt observations.csv loads.csv fanout_latency.csv model.rpt model.tcl estimates.csv run.log}
    foreach name $output_names {
        if {[file exists [file join $directory $name]] && ![dict get $options -overwrite]} {
            error "Output exists: [file join $directory $name]. Select another directory or use -overwrite 1."
        }
    }
    file mkdir $directory
    if {[dict get $options -overwrite]} {
        foreach name $output_names {
            set target [file join $directory $name]
            if {[file isfile $target]} {file delete -- $target}
        }
    }
    set windows_cache {}; set warnings {}; set last_model {}
    set old_instance [current_instance .]
    set old_save [get_app_var timing_save_pin_arrival_and_slack]
    set code [catch {
        current_instance
        set_app_var timing_save_pin_arrival_and_slack true
        update_timing
        set scale [time_scale $design $options]
        set sinks [sink_index $options]
        if {[dict size $sinks] == 0} {warn "No eligible DFF/latch clock pins were found."}
        set blocks [block_list $options]
        set rows [collect $design $blocks $sinks $options $scale]
        if {[llength $rows] == 0} {warn "No recognized clock inputs. Check propagated clocks, the pin/port clocks attribute, and clock patterns."}
        set answer [write_reports $design $blocks $rows $options $scale]
    } result error_options]
    close_outputs
    set cleanup_errors {}
    if {[catch {set_app_var timing_save_pin_arrival_and_slack $old_save} msg]} {lappend cleanup_errors "restore timing_save_pin_arrival_and_slack: $msg"}
    if {[catch {
        current_instance
        if {$old_instance ne {}} {current_instance $old_instance}
    } msg]} {lappend cleanup_errors "restore current_instance: $msg"}
    set windows_cache {}
    if {$code || [llength $cleanup_errors]} {
        set last_model {}
        catch {
            set ch [open [file join $directory run.log] w]
            puts $ch "status=FAILED"
            puts $ch "error=$result"
            puts $ch "cleanup_errors=$cleanup_errors"
            if {$code && [dict exists $error_options -errorinfo]} {puts $ch [dict get $error_options -errorinfo]}
            close $ch
        }
        if {$code} {return -options $error_options $result}
        error "Analysis finished but state restoration failed: $cleanup_errors"
    }
    puts "CG_LATENCY: COMPLETE; reports: $directory; model: [dict get $answer model_status]"
    return $answer
}
