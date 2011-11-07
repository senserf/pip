#!/bin/sh
########\
exec tclsh85 "$0" "$@"

package require Tk
package require Ttk

###############################################################################
# Determine the system type ###################################################
###############################################################################

if [catch { exec uname } ST(SYS)] {

	set ST(SYS) "W"

} elseif [regexp -nocase "linux" $ST(SYS)] {

	set ST(SYS) "L"

} elseif [regexp -nocase "cygwin" $ST(SYS)] {

	set ST(SYS) "C"

} else {

	set ST(SYS) "W"
}

###############################################################################
# Will be set by deploy
set PicOSPath	""
set DefProjDir	""

set EditCommand "elvis -f ram -m -G x11 -font 9x15"
## Delay after opening a new elvis and before the first command to it can be
## issued
set NewCmdDelay 300
set TagsCmd "elvtags"
set TagsArgs "-l -i -t -v -h -l --"

if { $ST(SYS) == "L" } {
	set SIDENAME "side"
} else {
	set SIDENAME "side.exe"
}

## File types to be listed in the Files view:
## header label, file qualifying patterns, filetypes [for tk_getSaveFile]
set LFTypes {
	{ Headers { "\\.h$" "\\.ch$" } { Header { ".h" ".ch" } } }
	{ Sources { "\\.cc?$" "\\.asm$" } { Source { ".cc" } } }
	{ Options { "^options\[_a-z\]*\\.sys$" } { Options { ".sys" } } }
	{ XMLData { "\\.xml$" "\\.geo$" } { XMLData { ".xml" ".geo" } } }
}

## Directory names to be ignored in the project's directory:
## strict names, patterns (case ignored)
set IGDirs { "^cvs$" "^vuee_tmp$" "^ktmp" "junk" "attic" "ossi" "\\~\\$" 
		"\[ \t.\]" }

## Dictionary of configuration items (to be searched for in config.prj) + their
## default values
set CFBoardItems {
			"CPU" 		"MSP430"
			"MB" 		0
			"BO" 		""
}

set CFVueeItems {
			"CMPIS"		0
			"UDON"		0
			"UDDF"		""
			"VUDF"		""
}

## Names of the configurable loaders (just two for now)
set CFLDNames { ELP MGD }

## Configuration data for loaders; not much for now. We assume there are two
## loaders: the Elprotronic Lite (which only requires the path to the
## executable), and msp430-gdb, which requires the device + the arguments to
## gdbproxy; LDSEL points to the "selected" loader. The selection may make
## little sense now, because, given the system (Windows, Linux), there is only
## one choice (but this may change later)
set CFLoadItems {
			"LDSEL"		""
			"LDELPPATH"	""
			"LDMGDDEV"	""
			"LDMGDARG"	""
		}

set CFItems 	[concat $CFBoardItems $CFVueeItems $CFLoadItems]

## List of legal CPU types
set CPUTypes { MSP430 eCOG }

## List of last projects
set LProjects ""

##
## Status of external programs
##
## Program running in term

## Output fd of the program running in term
set TCMD(FD) ""

## Accumulated input chunk arriving from the program running in term
set TCMD(BF) ""

## BOL flag: 1 if line started but not yet completed
set TCMD(BL) 0

## Callback (after) to visualize that something is running in term
set TCMD(CB) ""

## Counter used by the callback
set TCMD(CL) 0

## File descriptor of the udaemon pipe (!= "" -> udaemon running)
set TCMD(FU) ""

## File descriptor of the genimage pipe
set TCMD(FG) ""

## Process ID of FET loader (!= "" -> FET loader is running) + callback
## to monitor its disappearance + signal to kill + action to be performed
## after kill; on Cygwin, a periodic callback seems to be the only way to
## learn that a background process has disappeared
set TCMD(FL) ""
set TCMD(FL,CB) ""
set TCMD(FL,SI) "INT"
set TCMD(FL,AC) "reset_exec_menu"

## Slots for up to 4 instances of piter, CPITERS counts them, so we can order
## them dynamically
set TCMD(NPITERS) 4
set TCMD(CPITERS) 0
for { set p 0 } { $p < $TCMD(NPITERS) } { incr p } {
	set TCMD(PI$p) ""
	set TCMD(PI$p,SN) 0
}

## Running status (tex variable) of term + running "value" (number of seconds)
set P(SSL) ""
set P(SSV) ""

## double exit avoidance flag
set REX	0

## This is the insert into the path to a Windows 7 executable to get to the
## user-specific copy of Program Files where programs like the Elprotronics
## programmer write dynamic config files, e.g., if the true program path is:
## C:/Program Files/Elprotronic/MSP430/FET-Pro430/..., the config will be at:
## C:/Users/-user-/AppData/Local/VirtualStore/Program Files/Elprotronic/
## MSP430/FET-Pro430/config.ini; note that env(LOCALAPPDATA) contains
## C:/Users/-user-/AppData/Local, so maybe VirtualStore is a sufficient hint?
set ElpConfPath7 "AppData/Local/VirtualStore"

###############################################################################

proc log { m } {

	puts $m
}

###############################################################################

proc isspace { c } {
	return [regexp "\[ \t\n\r\]" $c]
}

proc isnum { c } {
	return [regexp -nocase "\[0-9\]" $c]
}

###############################################################################

proc delay { msec } {
#
# Event admitting "after"
#
	global P

	if { [info exists P(DEL)] && $P(DEL) != "" } {
		catch { after cancel $P(DEL) }
	}

	set P(DEL) [after $msec delay_trigger]
	vwait P(DEL)
	unset P(DEL)
}

proc delay_trigger { } {

	global P

	if ![info exists P(DEL)] {
		return
	}

	set P(DEL) ""
}

###############################################################################

proc unimpl { } {
#
	alert "Not implemented yet"
}
	
proc xq { pgm { pargs "" } } {
#
# A flexible exec (or so I hope)
#
	set ef [auto_execok $pgm]
	if ![file executable $ef] {
		set ret [eval [list exec] [list sh] [list $ef] $pargs]
	} else {
		set ret [eval [list exec] [list $ef] $pargs]
	}
	return $ret
}

proc alert { msg } {

	tk_dialog .alert "Attention!" "${msg}!" "" 0 "OK"
}

proc confirm { msg } {

	return [tk_dialog .alert "Warning!" $msg "" 0 "NO" "YES"]
}

proc trunc_fname { n fn } {
#
# Truncate a file name to be displayed
#
	if { $fn == "" } {
		return "---"
	}

	set ln [string length $fn]
	if { $ln > $n } {
		set fn "...[string range $fn end-[expr $n - 3] end]"
	}
	return $fn
}

proc term_addtxt { txt } {

	global Term

	$Term configure -state normal
	$Term insert end "$txt"
	$Term configure -state disabled
	$Term yview -pickplace end
}

proc term_endline { } {

	global TCMD Term

	$Term configure -state normal
	$Term insert end "\n"

	while 1 {
		set ix [$Term index end]
		set ix [string range $ix 0 [expr [string first "." $ix] - 1]]
		if { $ix <= 1024 } {
			break
		}
		# delete the topmost line if above limit
		$Term delete 1.0 2.0
	}

	$Term configure -state disabled
	# make sure the last line is displayed
	$Term yview -pickplace end
	# BOL flag
	set TCMD(BL) 0
}

proc term_dspline { ln } {
#
# Write a line to the terminal
#
	global TCMD

	if $TCMD(BL) {
		term_endline
	}
	term_addtxt $ln
	term_endline
}

proc term_output { } {

	global TCMD

	if [catch { read $TCMD(FD) } chunk] {
		# assume EOF
		stop_term
		return
	}

	if [eof $TCMD(FD)] {
		stop_term
		return
	}

	if { $chunk == "" } {
		return
	}

	# filter out non-printable characters
	while { ![string is ascii -failindex el $chunk] } {
		set chunk [string replace $chunk $el $el]
	}

	append TCMD(BF) $chunk
	# look for CR+LF, LF+CR, CR, LF; if there is only one of those at the
	# end, ignore it for now and keep for posterity
	set sl [string length $TCMD(BF)]

	while { [regexp "\[\r\n\]" $TCMD(BF) m] } {
		set el [string first $m $TCMD(BF)]
		if { $el == 0 } {
			# first character
			if { $sl < 2 } {
				# have to leave it and wait
				return
			}
			# check the second one
			set n [string index $TCMD(BF) 1]
			if { $m == "\r" && $n == "\n" || \
			     $m == "\n" && $n == "\r"    } {
				# two-character EOL
				set TCMD(BF) [string range $TCMD(BF) 2 end]
				incr sl -2
			} else {
				set TCMD(BF) [string range $TCMD(BF) 1 end]
				incr sl -1
			}
			# complete previous line
			term_endline
			set TCMD(BL) 0
			continue
		}
		# send the preceding string to the terminal
		term_addtxt [string range $TCMD(BF) 0 [expr $el - 1]]
		incr sl -$el
		set TCMD(BL) 1
		set TCMD(BF) [string range $TCMD(BF) $el end]
	}

	if { $TCMD(BF) != "" } {
		term_addtxt $TCMD(BF)
		set TCMD(BL) 1
		set TCMD(BF) ""
	}
}

###############################################################################

proc read_piprc { } {
#
# Read the rc file
#
	global env

	if ![info exists env(HOME)] {
		return ""
	}

	if [catch { open [file join $env(HOME) ".piprc"] "r" } fd] {
		# cannot open rc file
		return ""
	}

	if [catch { read $fd } rf] {
		catch { close $fd }
		return ""
	}

	catch { close $fd }

	return $rf
}

proc write_piprc { f } {
#
# Write the rc file
#
	global env

	if ![info exists env(HOME)] {
		return
	}

	if [catch { open [file join $env(HOME) ".piprc"] "w" } fd] {
		# cannot open rc file
		return
	}

	catch { puts -nonewline $fd $f }
	catch { close $fd }
}

proc get_last_project_list { } {
#
# Retrieve the list of last projects from .piprc
#
	global LProjects

	set rc [read_piprc]
	if [catch { dict get $rc "LPROJECTS" } lpr] {
		set lpr ""
	}

	set LProjects $lpr
	catch { reset_file_menu }
}

proc upd_last_project_list { } {
#
# Update the last projects list in .piprc
#
	global LProjects

	set rc [read_piprc]
	catch { dict set rc "LPROJECTS" $LProjects }
	write_piprc $rc
	catch { reset_file_menu }
}

###############################################################################

proc file_present { f } {
#
# Checks if the file is present as a regular file
#
	if { [file exists $f] && [file isfile $f] } {
		return 1
	}
	return 0
}

proc reserved_dname { d } {
#
# Checks a root directory name against being reserved
#
	global IGDirs

	foreach m $IGDirs {
		if [regexp -nocase $m $d] {
			return 1
		}
	}
	return 0
}

proc file_class { f } {
#
# Checks if the file name formally qualifies the file as a project member
#
	global LFTypes

	foreach t $LFTypes {
		foreach p [lindex $t 1] {
			if [regexp $p $f] {
				return $t
			}
		}
	}
	return ""
}

proc inside_project { f } {
#
# Checks if the specified path refers to something inside the project
#

	if { [string first [file normalize [pwd]] [file normalize $f]] == 0 } {
		# OK
		return 1
	}
	return 0
}

proc relative_path { f } {
#
# Transforms an absolute path into a project-relative path (just to shorten it,
# but also to make it independent of Cygwin/Tcl mismatches
#
	set f [file normalize $f]
	set c [file normalize [pwd]]

	if { [string first $c $f] != 0 } {
		# not in project
		return ""
	}

	set f [string range $f [string length $c] end]
	regsub "^//*" $f "" f
	return $f
}

proc gfl_tree { } {
#
# Fill/update the treeview file list with files
#
	global LFTypes MKRECV P

	array unset MKRECV
	set fl [gfl_all_rec .]
	# we don't need this any more
	array unset MKRECV

	set tv $P(FL)

	# remove all nodes in treeview; will fill it from scratch
	$tv delete [$tv children {}]

	foreach t $LFTypes {
		# header title
		set h [lindex $t 0]
		# the list of items for this header, directories going first
		set l [gfl_spec $fl $h]
		set id [$tv insert {} end -text ${h}: -values [list $h "c"]]
		if [info exists P(FL,c,$h)] {
			set of 1
		} else {
			set of 0
		}
		$tv item $id -open $of
		# tree, parent, list, path so far
		gfl_tree_pop $tv $id $l ""
	}

	gfl_make_ctags
}

proc gfl_tree_pop { tv node lst path } {
#
# Populate the list of children of the given node with the current contents
# of the list
#
	global P EFST

	foreach t [lindex $lst 0] {
		# the directories
		set n [lindex $t 0]
		# augmented path
		set p [file join $path $n]
		set id [$tv insert $node end -text $n -values [list $p "d"]]
		# check if should be open or closed
		if [info exists P(FL,d,$p)] {
			# open
			set of 1
		} else {
			set of 0
		}
		$tv item $id -open $of
		# add recursively the children
		gfl_tree_pop $tv $id [lindex $t 1] $p
	}
	# now for the files
	foreach t [lindex $lst 1] {
		set p [file join $path $t]
		set f [file normalize $p]
		set u [file_edit_pipe $f]
		if { $u != "" } {
			# edited
			if { $EFST($u,M) > 0 } {
				# modified
				set tag sred
			} else {
				set tag sgreen
			}
			$tv insert $node end -text $t -values [list $p "f"] \
				-tags $tag
		} else {
			$tv insert $node end -text $t -values [list $p "f"]
		}
	}
}

proc gfl_all_rec { path } {
#
# The recursive part of gfl_tree; returns a two-element list { dirs files } or
# NULL is there is nothing more below this point
#
	global MKRECV

	if [catch { glob -directory $path -tails * } sdl] {
		# something wrong
		return ""
	}

	set dirs ""
	set fils ""

	foreach f $sdl {
		set p [file normalize [file join $path $f]]
		if { $p == "" } {
			# just in case
			continue
		}
		if [file isdirectory $p] {
			# should we ignore it
			if [info exists MKRECV($p)] {
				# avoid loops
				continue
			}
			set MKRECV($p) ""
			if [reserved_dname $f] {
				continue
			}
			set rfl [gfl_all_rec [file join $path $f]]
			lappend dirs [list $f $rfl]
			continue
		}
		# a regular file
		set t [file_class $f]
		if { $t != "" } {
			lappend fils [list [lindex $t 0] $f]
		}
	}
	return [list $dirs $fils]
}

proc gfl_spec { fl ft } {
#
# Given a combined global list of all qualified files, extracts from it a
# class-specific sublist; this time the directories and files at each level
# are sorted by name; note that they are sorted independently (the dirs are
# supposed to go first when the thing is displayed)
#
	set dirs ""
	set fils ""

	# flag == at least one file present here or down from here
	set fp 0

	foreach t [lindex $fl 0] {
		# directories first; the name
		set n [lindex $t 0]
		set rfl [gfl_spec [lindex $t 1] $ft]
		if { $rfl != "" || $ft == "Sources" } {
			# Sources also collects all empty directories
			set fp 1
			lappend dirs [list $n $rfl]
		}
	}
	set dirs [lsort -index 0 $dirs]

	foreach t [lindex $fl 1] {
		# files
		if { [lindex $t 0] != $ft } {
			# wrong type
			continue
		}
		# just the name
		lappend fils [lindex $t 1]
		set fp 1
	}

	if !$fp {
		return ""
	}

	set fils [lsort $fils]

	return [list $dirs $fils]
}

proc gfl_open { tree node } {
#
# Keep track of which ones are open and which ones are closed; we will need it
# for updates
#
	global P

	set t [$tree set $node type]

	if { $t == "c" || $t == "d" } {
		# mark it as open
		set P(FL,$t,[$tree set $node filename]) ""
	}
}

proc gfl_close { tree node } {

	global P

	set t [$tree set $node type]

	if { $t == "c" || $t == "d" } {
		array unset P "FL,$t,[$tree set $node filename]"
	}
}

proc gfl_files { { pat "" } } {
#
# Finds all files in the tree view matching the specified pattern
#
	global P

	set res ""

	foreach d [$P(FL) children {}] {
		# only headers at this level
		set lres [gfl_files_rec $d $pat]
		if { $lres != "" } {
			set res [concat $res $lres]
		}
	}
	return $res
}

proc gfl_files_rec { nd pat } {
#
# The recursive traverser for gfl_files
#
	global P

	set res ""

	foreach d [$P(FL) children $nd] {
		set vs [$P(FL) item $d -values]
		if { [lindex $vs 1] != "f" } {
			# not a file
			set lres [gfl_files_rec $d $pat]
			if { $lres != "" } {
				set res [concat $res $lres]
			}
		} else {
			set fn [lindex $vs 0]
			if { $pat == "" || [regexp $pat $fn] } {
				lappend res $fn
			}
		}
	}

	return $res
}

proc gfl_find { path } {
#
# Locates the node corresponding to the given file path
#
	global P

	foreach d [$P(FL) children {}] {
		# only headers at this level
		set node [gfl_find_rec $d $path]
		if { $node != "" } {
			return $node
		}
	}
	return ""
}

proc gfl_find_rec { nd path } {
#
# The recursive traverser for gfl_find
#
	global P

	foreach d [$P(FL) children $nd] {
		set vs [$P(FL) item $d -values]
		if { [lindex $vs 1] != "f" } {
			# not a file
			set node [gfl_find_rec $d $path]
			if { $node != "" } {
				return $node
			}
			continue
		}
		if { [file normalize [lindex $vs 0]] == $path } {
			return $d
		}
	}

	return ""
}

proc gfl_status { path val } {
#
# Change the color of file label in the tree based on the current file status
#
	global P

	set node [gfl_find $path]

	if { $node == "" } {
		return
	}

	if { $val < 0 } {
		$P(FL) item $node -tags {}
	} elseif { $val == 0 } {
		$P(FL) item $node -tags sgreen
	} else {
		$P(FL) item $node -tags sred
	}
}

proc gfl_make_ctags { } {
#
# Create ctags for all files in the current project. We do this somewhat
# nonchalantly (for all files) whenever we suspect that something has changed,
# like after editing a file. Note that this is still a toy implementation of
# our SDK. We shall worry about efficiency later (if ever).
#
	global P TagsCmd TagsArgs

	# the list of the proper files of the project
	set fl [gfl_files]

	array unset P "FL,T,*"

	if { $fl == "" } {
		# no files (yet?)
		return
	}

	if [catch { xq $TagsCmd [concat $TagsArgs $fl] } tl] {
		alert "Cannot generate tags: $tl"
		return
	}

	# preprocess the tags
	set tl [split $tl "\n"]
	foreach t $tl {
		if { [string index $t 0] == "!" } {
			# these are comments, ignore
			continue
		}
		if ![regexp "^(\[^\t\]+)\[\t\]+(\[^\t\]+)\[\t\]+(.+);\"" \
		    $t jnk ta fn cm] {
			# some garbage
			continue
		}
		if ![info exists P(FL,T,$ta)] {
			set P(FL,T,$ta) ""
		}
		set ne [list $fn $cm]
		if { [string tolower [file extension $fn]] == ".h" } {
			# headers have lower priority
			lappend P(FL,T,$ta) [list $fn $cm]
		} else {
			# other files go to front
			set P(FL,T,$ta) [concat [list $ne] $P(FL,T,$ta)]
		}
	}
}

###############################################################################

proc tag_request { fd tag } {
#
# Handles a tag request arriving from one of the editor sessions
#
	global P

	log "Tag request: $tag"

	if ![info exists P(FL,T,$tag)] {
		# alert "Tag $tag not found"
		term_dspline "Tag $tag not found"
		return
	}

	# check for a previous reference
	set nr 0
	if { [info exists P(FL,LT)] && [lindex $P(FL,LT) 0] == $tag } {
		# same tag referenced multiple times, get reference number
		set nr [lindex $P(FL,LT) 1]
		incr nr
		if { $nr >= [llength $P(FL,T,$tag)] } {
			# wrap around
			set nr 0
		}
	}
	set P(FL,LT) [list $tag $nr]

	set ne [lindex $P(FL,T,$tag) $nr]
	set fn [lindex $ne 0]
	set cm [lindex $ne 1]
	
	set fp [file normalize $fn]

	# get the pipe to the target file
	set u [file_edit_pipe $fp]

	if { $u == "" } {
		# not being edited, try to open it first
		edit_file $fp
		set u [file_edit_pipe $fp]
		if { $u == "" } {
			# failed for some reason
			log "Failed to open file $fm for tag"
			return
		}
	}

	# issue the command and raise the window
	edit_command $u $cm
}

###############################################################################

proc edit_file { fn } {

	global EFDS EFST EditCommand

	if [catch { open "|$EditCommand [list $fn]" "r+" } fd] {
		alert "Cannot start text editor: $fd"
		return
	}

	set EFDS($fd) $fn
	# file status; note: -1 means something like "unsettled"; we want to
	# use this value to mark the moment when the window has been opened
	# and the editor is ready, e.g., to accept commands from STDIN; I don't
	# know what is going on, but it appears that on Linux, if a command is
	# issued too soon, the edit session gets killed; another (minor) issue
	# is that initially the file status starts "modified" then immediately
	# becomes "not modified"; so we shall assume that the initial modified
	# status is ignored, and the true status becomes "settled" upon the
	# first perception of "not modified" status; if you are confused, you
	# are not alone
	set EFST($fd,M) -1
	# PID (unknown yet)
	set EFST($fd,P) ""
	# command queue
	set EFST($fd,C) ""
	# mark the status in the tree
	gfl_status $fn 0

	log "Editing file: $fn"

	fconfigure $fd -blocking 0 -buffering none
	fileevent $fd readable "edit_status_read $fd"
}

proc edit_status_read { fd } {

	global EFDS EFST

	if [catch { gets $fd line } val] {
		# aborted
		log "Edit session aborted"
		edit_close $fd 1
		return
	}

	if { $val < 0 } {
		# finished normally
		edit_close $fd 0
		return
	}

	set line [string trim $line]

	if [regexp "BST: (\[0-9\])" $line jnk st] {
		if { $EFST($fd,M) < 0 && $st > 0 } {
			# ignore the initial "modified" status, which is
			# bogus
			log "Bogus modified status ignored"
			return
		}
		if { $st != $EFST($fd,M) } {
			set os $EFST($fd,M)
			# an actual change
			log "Edit status change for $EFDS($fd): $EFST($fd,M) ->\
				$st"
			set EFST($fd,M) $st
			gfl_status $EFDS($fd) $st
			if { $os < 0 } {
				global NewCmdDelay
				delay $NewCmdDelay
				foreach c $EFST($fd,C) {
					catch { puts $fd $c }
				}
				set EFST($fd,C) ""
			}
		}
		return
	}

	if [regexp "TAG: +(.+)" $line jnk st] {
		tag_request $fd $st
		return
	}

	if [regexp "PID: (\[0-9\]+)" $line jnk st] {
		log "Edit process ID: $st"
		if { $EFST($fd,P) == "" } {
			set EFST($fd,P) $st
		}
		return
	}

	log "PIPE: $line"

	# room for more
}

proc edit_command { fd cmd } {

	global EFST

	if { $EFST($fd,M) < 0 } {
		# status "unsettled"
		lappend EFST($fd,C) $cmd
		log "Queueing command $cmd to $fd"
	} else {
		catch { puts $fd $cmd }
		log "Issuing command $cmd to $fd"
	}
}

proc edit_close { fd ab } {

	global EFST EFDS

	catch { close $fd }

	if [info exists EFDS($fd)] {
		# not an external kill, soft close
		if $ab {
			set ab "aborted"
		} else {
			set ab "closed"
		}
		log "Edit session $EFDS($fd) $ab"
		gfl_status $EFDS($fd) -1
		array unset EFST "$fd,*"
		unset EFDS($fd)
		# redo the file list; FIXME: don't do this, but redo tags, if
		# the file has (ever) changed
		gfl_tree
	}
}

proc edit_unsaved { } {

	global EFST EFDS

	set nf 0
	set ul ""

	foreach fd [array names EFDS] {
		if { $EFST($fd,M) > 0 } {
			incr nf
			append ul ", $EFDS($fd)"
		}
	}

	if { $nf == 0 } {
		# no unsaved files
		return 0
	}

	set ul [string range $ul 2 end]

	if { $nf == 1 } {
		alert "Unsaved file: $ul. Please save the file or close the\
			editing session and try again."
	} else {
		# more than one unsaved file
		alert "There are $nf unsaved files: $ul. Please save them or\
			close the editing sessions and try again."
	}

	# terminate the editing sessions

	return 1
}

proc close_modified { } {
#
# Closes the modified files, if the user says so
#
	global EFST EFDS

	set nf 0
	set ul ""
	set dl ""

	foreach fd [array names EFDS] {
		if { $EFST($fd,M) > 0 } {
			incr nf
			append ul "$EFDS($fd), "
			lappend dl $fd
		}
	}

	if { $nf == 0 } {
		# no unsaved files
		return 1
	}

	set ul [string range $ul 2 end]

	if { $nf == 1 } {
		set msg "This file: $ul has "
	} else {
		set msg "These files: $ul have "
	}
	append msg "been modified but not saved."

	set v [tk_dialog .alert "Attention!" $msg "" 0 \
		"Save" "Do not save" "Cancel"]

	if { $v == 1 } {
		# proceed as is
		return 1
	}

	if { $v == 2 } {
		# cancel
		return 0
	}

	# save the files
	foreach u $dl {
		edit_command $u "w!"
		delay 10
	}

	# wait for them to get saved
	for { set i 0 } { $i < 10 } { incr i } {
		delay 200
		set ul ""
		set nf 0
		foreach fd [array names EFDS] {
			if { $EFST($fd,M) > 0 } {
				incr nf
				append ul "$EFDS($fd), "
			}
		}
		if { $nf == 0 } {
			# done
			break
		}
		# keep waiting
	}

	if $nf {
		if { $nf > 1 } {
			set msg "Files "
		} else {
			set msg "File "
		}
		append msg "[string range $ul 2 end] couldn't be saved.\
			Do you want to proceed anyway?"

		return [confirm $msg]
	}

	return 1
}

proc edit_kill { { fp "" } } {

	global EFDS EFST

	foreach fd [array names EFDS] {
		if { $fp != "" && $EFDS($fd) != $fp } {
			# not this file
			continue
		}
		gfl_status $EFDS($fd) -1
		unset EFDS($fd)
		set pid $EFST($fd,P)
		array unset EFST($fd,*)
		if { $pid != "" } {
			log "Killing edit process: $pid"
			if [catch { exec kill -INT $pid } err] {
				log "Cannot kill: $err"
			}
		}
	}
}

proc file_is_edited { fn { m 0 } } {

	global EFDS EFST

	foreach fd [array names EFDS] {
		if { $EFDS($fd) == $fn } {
			if { $m == 0 || $EFST($fd,M) > 0 } {
				return 1
			}
		}
	}

	return 0
}

proc file_edit_pipe { fn } {

	global EFDS

	foreach fd [array names EFDS] {
		if { $EFDS($fd) == $fn } {
			return $fd
		}
	}

	return ""
}

proc open_for_edit { x y } {

	global P EFDS

	set tv $P(FL)
	set node [$tv identify item $x $y]

	if { $node == "" } {
		return
	}

	set vs [$tv item $node -values]

	if { [lindex $vs 1] != "f" } {	
		# not a file
		return
	}

	set fp [file normalize [lindex $vs 0]]
	set u [file_edit_pipe $fp]
	if { $u != "" } {
		# being edited
		edit_command $u ""
		# alert "The file is already being edited"
		return
	}
	edit_file $fp
}

proc do_file_line { w x y } {

	# this is the index of the character that has been clicked on
	set ix @$x,$y

	set if 0
	# go back until hit word boundary
	while 1 {
		set c [$w get -- "${ix} - $if chars"]
		if { $c == "" || [isspace $c] } {
			break
		}
		incr if
	}

	if { $if == 0 } {
		return
	}

	set ib 0
	# go forward
	while 1 {
		set c [$w get -- "${ix} + $ib chars"]
		if { $c == "" || [isspace $c] } {
			break
		}
		incr ib
	}

	incr if -1
	# starting index
	set if "${ix} - $if chars"
	set chunk [$w get -- $if "${ix} + $ib chars"]

	# nc points to the last character of the line number
	if { ![regexp "^(.+):(\[1-9\]\[0-9\]*):\[0-9\]" $chunk ma fn ln] &&
	     ![regexp "^(.+):(\[1-9\]\[0-9\]*)" $chunk ma fn ln] } {
		# doesn't look like a line number in a file
		set chunk [string trimright $chunk ":,;"]
		if { $chunk == "" || [file_class $chunk] == "" } {
			return
		}
		set fn $chunk
		set ma $chunk
		set ln 0
	}

	# ending index for the tag
	set ib [string length $ma]

	log "File line ref: $fn, $ln"

	if [catch { expr $ln } $ln] {
		log "File line number error"
		return
	}

	# try to match the file to one of the project files; FIXME: this will
	# have to be made smarter, to account for the various manglings
	# performed by picomp
	set ft [file tail $fn]
	set fr [file root $ft]
	set fe [file extension $ft]

	# all project files matching the extension
	set fl [gfl_files "\\${fe}$"]

	# the length of root portion of the file name
	set rl [string length $fr]

	# current quality
	set qu 99999

	# current file name
	set fm ""

	foreach f $fl {
		set r [file root [file tail $f]]
		if { $r == $f } {
			# ultimate match
			set fm $f
			break
		}
		if { [string first $r $fr] >= 0 } {
			# substring
			set q [expr $rl - [string length $r]]
			if { $q < $qu } {
				set qu $q
				set fm $f
			}
		}
	}

	if { $fm == "" } {
		log "No matching file found"
		return
	}

	# open the file at the indicated line
	set fm [file normalize $fm]
	set u [file_edit_pipe $fm]
	if { $u == "" } {
		edit_file $fm
		set u [file_edit_pipe $fm]
		if { $u == "" } {
			log "Failed to open file $fm for err ref"
			return
		}
	}

	# issue the positioning command if line number was present
	if $ln {
		edit_command $u $ln
	}
	$w tag add errtag $if "$if + $ib chars"
}

proc tree_selection { { x "" } { y "" } } {
#
# Construct the list of selected (or pointed to) items
#
	global P

	set tv $P(FL)

	# first check if there's a selection
	set fl ""
	foreach t [$tv selection] {
		# make sure we only look at file/directory items
		set vs [$tv item $t -values]
		set tp [lindex $vs 1]
		if { $tp == "f" || $tp == "d" } {
			lappend fl $vs
		}
	}

	if { $fl != "" || $x == "" } {
		# that's it: selection takes precedence over pointer
		return $fl
	}

	# no selection and pointer present, check if it is pointing at some file
	set t [$tv identify item $x $y]
	if { $t == "" } {
		return ""
	}
	set vs [$tv item $t -values]
	set tp [lindex $vs 1]
	if { $tp == "f" || $tp == "d" } {
		lappend fl $vs
	}

	return $fl
}

proc tree_menu { x y X Y } {

	# create the menu
	catch { destroy .popm }
	set m [menu .popm -tearoff 0]

	$m add command -label "Edit" -command "open_multiple $x $y"
	$m add command -label "Delete" -command "delete_multiple $x $y"
	$m add command -label "Rename ..." -command "rename_file $x $y"
	$m add command -label "New file ..." -command "new_file $x $y"
	$m add command -label "Copy from ..." -command "copy_file $x $y"
	$m add command -label "New directory ..." -command "new_directory $x $y"

	tk_popup .popm $X $Y
}

proc open_multiple { { x "" } { y "" } } {
#
# Open files for editing
#
	global P

	if !$P(AC) {
		return
	}

	set sel [tree_selection $x $y]

	set fl ""
	foreach f $sel {
		# select files only
		if { [lindex $f 1] == "f" } {
			lappend fl [lindex $f 0]
		}
	}

	if { $fl == "" } {
		return
	}

	if { [llength $fl] == 1 } {
		set fp [file normalize [lindex $fl 0]]
		if [file_is_edited $fp] {
			alert "The file is already being edited"
		} else {
			edit_file $fp
		}
		return
	}

	set el ""
	foreach f $fl {
		set fp [file normalize $f]
		if ![file_is_edited $fp] {
			lappend el $fp
		}
	}

	if { $el == "" } {
		alert "All these files are already being edited"
		return
	}

	foreach fp $el {
		edit_file $fp
	}
}

proc delete_multiple { { x "" } { y "" } } {
#
# Delete files or directories (the latter must be empty)
#
	global P

	if !$P(AC) {
		return
	}

	set sel [tree_selection $x $y]

	set fl ""
	foreach f $sel {
		# files first
		if { [lindex $f 1] == "f" } {
			lappend fl [lindex $f 0]
		}
	}

	if { $fl != "" } {
		delete_files $fl
	}

	# now go for directories
	set fl ""
	foreach f $sel {
		if { [lindex $f 1] == "d" } {
			lappend fl [lindex $f 0]
		}
	}

	if { $fl != "" } {
		delete_directories $fl
	}

	# redo the tree view
	gfl_tree
}

proc delete_directories { fl } {

	set ne ""
	set de ""

	foreach f $fl {
		if [catch { glob -directory $f * } fils] {
			set fils ""
		}
		if { $fils != "" } {
			# nonempty
			lappend ne $f
		} else {
			lappend de $f
		}
	}

	if { $ne != "" } {
		set msg "Director"
		if { [llength $ne] > 1 } {
			append msg "ies: [join $ne ", "] are "
			set wh "their"
		} else {
			append msg "y: [lindex $ne 0] is "
			set wh "its"
		}
		append msg "nonempty. You must delete $wh contents first"
		alert $msg
	}

	# proceed with the empty ones

	foreach f $de {
		log "Deleting file: $f"
		catch { file delete -force -- [file normalize $f] }
	}
}

proc delete_files { fl } {

	set msg "Are you sure you want to delete "

	if { [llength $fl] < 2 } {
		append msg "this file: [lindex $fl 0]"
	} else {
		append msg "these files: "
		append msg [join $fl ", "]
	}
	append msg "?"

	if ![confirm $msg] {
		return
	}

	# check for modification
	set mf ""

	foreach f $fl {
		if [file_is_edited [file normalize $f] 1] {
			lappend mf $f
		}
	}

	if { $mf != "" } {
		set msg "File"
		if { [llength $mf] > 1 } {
			append msg "s: "
			append msg [join $mf ", "]
			append msg " have"
		} else {
			append msg ": [lindex $mf 0] has"
		}
		append msg " been edited and modified but not yet\
			saved. If you proceed, the edit sessions will\
			be closed and the changes will be discarded."
		if ![confirm $msg] {
			return
		}
	}

	# delete
	foreach f $fl {
		set fp [file normalize $f]
		edit_kill $fp
		log "Deleting file: $fp"
		catch { file delete -force -- $fp }
	}
}

###############################################################################

proc md_click { val } {
#
# Generic done event for modal windows/dialogs
#
	global P

	if { [info exists P(MW,EV)] && $P(MW,EV) == 0 } {
		set P(MW,EV) $val
	}
}

proc md_stop { } {
#
# Close operation for a modal window
#
	global P

	if [info exists P(MW,WI)] {
		catch { destroy $P(MW,WI) }
	}
	array unset P "MW,*"
}

proc md_wait { } {
#
# Wait for an event on the modal dialog
#
	global P

	set P(MW,EV) 0
	vwait P(MW,EV)
	if ![info exists P(MW,EV)] {
		return -1
	}
	if { $P(MW,EV) < 0 } {
		# cancellation
		md_stop
		return -1
	}

	return $P(MW,EV)
}

proc md_window { tt } {
#
# Creates a modal dialog
#
	global P

	set w .modd
	catch { destroy $w }
	set P(MW,WI) $w
	toplevel $w
	wm title $w $tt
	# this fails sometimes
	catch { grap $w }

	return $w
}

###############################################################################

proc bad_dirname { } {

	alert "The new directory name is illegal, i.e., is reserved or\
		includes a disallowed exotic character"
}

proc new_directory { { x "" } { y "" } } {
#
# Creates a new directory in the project's directory
#
	global P

	if !$P(AC) {
		# ignore if no project
		return
	}

	set dir [lindex [tree_sel_params] 0]

	mk_new_dir_window $dir

	while 1 {

		set ev [md_wait]

		if { $ev < 0 } {
			# cancellation
			return
		}

		if { $ev == 0 } {
			# nothing
		}

		# validate the directory
		set nd [file normalize [file join $dir $P(MW,DI)]]
		if ![inside_project $nd] {
			alert "The new directory is outside the project tree"
			continue
		}
		if [reserved_dname [file tail $nd]] {
			bad_dirname
			continue
		}
		if [file isdirectory $nd] {
			alert "Directory $nd already exists"
			continue
		}
		log "Creating directory: $nd"
		if [catch { file mkdir $nd } err] {
			alert "Cannot create directory $nd: $err"
			continue
		}

		md_stop
		gfl_tree
		return
	}
}

proc mk_new_dir_window { dir } {
#
# Opens a dialog to specify a new directory
#
	global P

	set w [md_window "New directory"]

	frame $w.tf
	pack $w.tf -side top -expand y -fill x

	label $w.tf.l -text "$dir / "
	pack $w.tf.l -side left -expand n -fill x

	set P(MW,DI) "NEW_DIR"
	entry $w.tf.e -width 8 -font {-family courier -size 10} \
			-textvariable P(MW,DI)
	pack $w.tf.e -side left -expand y -fill x

	frame $w.bf
	pack $w.bf -side top -expand y -fill x

	button $w.bf.b -text "Done" -command "md_click 1"
	pack $w.bf.b -side right -expand n -fill x

	button $w.bf.c -text "Cancel" -command "md_click -1"
	pack $w.bf.c -side left -expand n -fill x

	bind $w <Destroy> "md_click -1"
}

proc tree_sel_params { { x "" } { y "" } } {
#
# Returns the list of selection parameters { dir, type, extension } forcing
# the interpretation as a single selection. Used to determine, e.g., the
# target directory of a new file
#
	global P

	set tv $P(FL)

	set t [$tv selection]

	if { [llength $t] != 1 && $x != "" } {
		# use the pointer
		set t [$tv identify item $x $y]
	} else {
		# use the selection
		set t [lindex $t 0]
	}

	# the defaults
	set dir "."
	set typ Sources
	set ext ""

	while 1 {
		if { $t == "" } {
			# don't know
			break
		}
		set vs [$tv item $t -values]
		set tp [lindex $vs 1]
		if { $tp == "d" } {
			# use this directory and look up the parent class
			if { $dir == "." } {
				# first directory on our path up
				set dir [lindex $vs 0]
			}
			while 1 {
				set t [$tv parent $t]
				if { $t == "" } {
					# will redo for "unknown"
					break
				}
				if { [lindex [$tv item $t -values] 0] == "c" } {
					# the top, i.e., the class node
					break
				}
			}
			# redo for unknown or class
			continue
		}

		set fn [lindex $vs 0]

		if { $tp == "c" } {
			# class, force the suffix
			set typ $fn
			break
		}

		# file
		set ext [file extension $fn]
		set dir [file dirname $fn]

		# determine types from the class
		set t [$tv parent $t]
	}

	return [list $dir $typ $ext]
}

proc new_file { { x "" } { y "" } } {

	global P LFTypes

	if !$P(AC) {
		return
	}

	lassign [tree_sel_params] dir typ ext

	set fo 1
	foreach t $LFTypes {
		if { [lindex $t 0] == $typ } {
			set fo 0
			break
		}
	}

	if $fo {
		# impossible, assume Sources
		set t [lindex $LFTypes 1]
	}

	set typ [list [lindex $t 2]]
	if { $ext == "" } {
		# the first extension from filetypes
		set ext [lindex [lindex [lindex $typ 0] 1] 0]
	}

	set dir [file normalize $dir]

	while 1 {

		set fn [tk_getSaveFile \
				-defaultextension $ext \
				-filetypes $typ \
				-initialdir $dir \
				-title "New file"]

		if { $fn == "" } {
			# cancelled
			return
		}

		set fn [file normalize $fn]

		if { [file_class $fn] == "" } {
			alert "Illegal file name or extension"
			continue
		}

		if ![inside_project $fn] {
			alert "This file is located outside the project's\
				directory"
			continue
		}

		if [file exists $fn] {
			alert "This file already exists"
			continue
		}

		break
	}

	catch { exec touch $fn }
	gfl_tree
	edit_file $fn
}

proc copy_file { { x "" } { y "" } } {
#
# Copies an external file (or a bunch of files) to a project's directory
#
	global P

	if !$P(AC) {
		return
	}

	# the target directory
	set dir [lindex [tree_sel_params] 0]

	if ![info exists P(LCF)] {
		global DefProjDir
		set P(LCF) $DefProjDir
	}

	while 1 {

		set fl [tk_getOpenFile \
			-initialdir $P(LCF) \
			-multiple 1 \
			-title "Select file(s) to copy:"]

		if { $fl == "" } {
			# cancelled
			return
		}

		# in the future start from here
		set P(LCF) [file dirname [lindex $fl 0]]

		# verify the extensions
		set ef ""
		foreach f $fl {
			if { [file_class $f] == "" } {
				lappend ef $f
			}
		}

		if { $ef == "" } {
			break
		}

		if { [llength $ef] > 1 } {
			set msg "These files: "
			append msg [join $ef ", "]
			append msg " have names/extensions that do not"
		} else {
			set msg "This file: [lindex $ef 0]"
			append msg " has name/extension that does not"
		}
		append msg " fit the project. Nothing copied. Select again"
		alert $msg
	}

	set ef ""
	foreach f $fl {
		set t [file tail $f]
		set u [file join $dir $t]
		if [file exists $u] {
			if ![confirm "File $t already exists in the target\
			    directory. Overwrite?"] {
				continue
			}
		}
		log "Copy file: $f -> $u"
		if [catch { file copy -force -- $f $u } err] {
			lappend ef $f
		}
	}

	if { $ef != "" } {
		if { [llength $ef] > 1 } {
			set msg "These files: "
			append msg [join $ef ", "]
		} else {
			set msg "This file: [lindex $ef 0]"
		}
		append msg " could not be copied. Sorry"
		alert $msg
	}


	gfl_tree
}

proc rename_file { { x "" } { y "" } } {
#
# Renames a file or directory
#
	global P

	if !$P(AC) {
		return
	}

	set sel [tree_selection]

	if { $sel == "" } {
		return
	}

	if { [llength $sel] > 1 } {
		alert "You can only rename one thing at a time"
		return
	}

	set f [lindex $sel 0]
	# type: d or f
	set t [lindex $f 1]

	set fn [lindex $f 0]
	set ta [file tail $fn]

	mk_rename_window $ta

	while 1 {

		set ev [md_wait]

		if { $ev < 0 } {
			# cancellation
			return
		}

		if { $ev > 0 } {
			# proceed with rename
			set nm $P(MW,NW)
			if { $nm == $ta } {
				alert "This will do nothing"
				continue
			}
			if { $nm == "" } {
				alert "The new name cannot be empty"
				continue
			}
			if [regexp "\[\\\\/ \t;\]" $nm] {
				alert \
				    "The new name $nm has an illegal character"
				continue
			}
			if { $t == "d" } {
				if [reserved_dname $nm] {
					bad_dirname
					continue
				}
			} else {
				if { [file_class $nm] == "" } {
					alert "The new file name is illegal or\
						has an illegal extension"
					continue
				}
			}
			# do it
			set tf [file join [file dirname $fn] $nm]

			if [file exists $tf] {
				if ![confirm "File $tf already exists. Do you\
				    want me to try to overwrite?"] {
					continue
				}
			}

			log "Rename file: $fn -> $tf"
			if [catch { file rename -force -- $fn $tf } err] {
				# failed
				alert "Couldn't rename: $err"
				continue
			}
			break
		}
	}

	md_stop
	gfl_tree
}
					
proc mk_rename_window { old } {
#
# Opens a dialog to rename a file or directory
#
	global P

	set [md_window "Rename"]

	frame $w.tf
	pack $w.tf -side top -expand y -fill x

	label $w.tf.l -text "$old ---> "
	pack $w.tf.l -side left -expand n -fill x

	set P(MW,NW) $old
	entry $w.tf.e -width 16 -font {-family courier -size 10} \
			-textvariable P(MW,NW)
	pack $w.tf.e -side left -expand y -fill x

	frame $w.bf
	pack $w.bf -side top -expand y -fill x

	button $w.bf.b -text "Done" -command "md_click 1"
	pack $w.bf.b -side right -expand n -fill x

	button $w.bf.c -text "Cancel" -command "md_click -1"
	pack $w.bf.c -side left -expand n -fill x

	bind $w <Destroy> "md_click -1"
}

###############################################################################

proc val_prj_dir { dir } {
#
# Validate the formal location of a project directory
#
	global PicOSPath

	set apps [file normalize [file join $PicOSPath Apps]]

	while 1 {
		set d [file normalize [file dirname $dir]]
		if { $d == $dir } {
			# no change
			alert "This directory won't do! A project directory\
				must be a proper subdirectory of $apps"
			return 0
		}
		if { $d == $apps } {
			# OK
			return 1
		}
		set dir $d
	}
}

proc prj_name { dir } {

	global PicOSPath

	return [string trim [string range $dir [string length \
		[file normalize [file join $PicOSPath Apps]]] end] "/"]
}

proc val_prj_incomp { } {
#
# Just an alert
#
	alert "Inconsistent contents of the project's directory: app.cc cannot\
		coexist with app_... files"
}

proc val_prj_exists { dir { try 0 } } {
#
# Check if the directory contains an existing project that appears to be making
# sense; try != 0 -> don't start it - just check, try < 2 -> issue alerts
#
	global P

	if ![file isdirectory $dir] {
		if { $try <= 1 } {
			alert "The project directory $dir does not exist"
		}
		return 0
	}

	if { [catch { glob -directory $dir -tails * } fl] || $fl == "" } {
		# this will not happen
		if { $try <= 1 } {
			alert "The project directory $dir is empty"
		}
		return 0
	}

	set pl ""
	set es 0

	foreach fn $fl {
		if { $fn == "app.cc" } {
			if { $pl != "" } {
				if { $try <= 1 } {
					val_prj_incomp
				}
				# return code == not a project, but nonempty
				return -1
			}
			set es 1
			continue
		}
		if { $fn == "app.c" } {
			if { $try <= 1 } {
				alert "This looks like a legacy praxis:\
					file app.c is incompatible with our\
					projects, please convert manually and\
					try again"
			}
			return -1
		}
		if [regexp "^app_(\[a-zA-Z0-9\]+)\\.cc$" $fn jnk pn] {
			if $es {
				if { $try <= 1 } {
					val_prj_incomp
				}
				return -1
			}
			lappend pl $pn
		}
	}

	if { !$es && $pl == "" } {
		if { $try <= 1 } {
			alert "There is nothing resembling a PicOS project in\
				directory $dir"
		}
		return -1
	}

	if $try {
		# do no more
		return 1
	}

	# time to close the previous project and assume the new one

	if [catch { cd $dir } err] {
		alert "Cannot move to the project's directory $dir: $err"
		return 0
	}

	array unset P "FL,d,*"
	array unset P "FL,c,*"
	array unset P "FL,T,*"

	set P(PL) $pl

	wm title . "Project: [prj_name $dir]"

	gfl_tree

	return 1
}

proc clone_project { } {
#
# Clone a project directory to another directory
#
	global P DefProjDir

	if [close_project] {
		# cancelled 
		return
	}

	while 1 {
		# select source directory
		set sdir [tk_chooseDirectory -initialdir $DefProjDir \
			-mustexist 1 \
			-title "Select the source directory:"]
		if { $sdir == "" } {
			# cancelled
			return
		}

		# check if this is a proper subdirectory of DefProjDir
		set sdir [file normalize $sdir]

		if ![val_prj_dir $sdir] {
			continue
		}

		if { [val_prj_exists $sdir 1] > 0 } {
			break
		}
	}

	while 1 {
		# select target directory
		set dir [tk_chooseDirectory -initialdir $DefProjDir \
			-title "Select the target directory:"]
		if { $dir == "" } {
			# cancelled
			return
		}

		# check if this is a proper subdirectory of DefProjDir
		set dir [file normalize $dir]

		if ![val_prj_dir $dir] {
			continue
		}

		set v [val_prj_exists $dir 2]

		if { $v != 0 } {
			if { $v > 0 } {
				set tm "Directory $dir contains something that\
					looks like an existing project!"
			} else {
				set tm "Directory $dir is not empty!"
			}
			append tm " Do you want to erase its contents?\
				THIS CANNOT BE UNDONE!!!"
			if ![confirm $tm] {
				continue
			}
		}

		if [file exists $dir] {
			# we remove the directory and create it from scratch
			if [catch { file delete -force -- $dir } err] {
				alert "Cannot erase $dir: $err"
				continue
			}
		}

		# copy source to target
		log "Copy project: $sdir $dir"
		if [catch { file copy -force -- $sdir $dir } err] {
			alert "Cannot copy $sdir to $dir: $err"
			continue
		}

		break
	}

	# now open as a ready project
	open_project -1 $dir
}

proc close_project { } {

	global P

	if [edit_unsaved] {
		# no
		return 1
	}

	edit_kill

	if $P(AC) {
		# this is used to tell if a project is currently opened;
		# perhaps we should've checked it before edit_unsaved?
		set P(AC) 0
		set P(CO) ""
		# in case something is running
		abort_term
		stop_udaemon
	}

	return 0
}

proc open_project { { which -1 } { dir "" } } {

	global P DefProjDir PicOSPath LProjects

	if [close_project] {
		# no
		return
	}

	if { $which < 0 } {

		# open file

		if { $dir != "" } {

			# use the specified directory
			set dir [file normalize $dir]
			if { [val_prj_exists $dir] <= 0 } {
				return
			}

		} else {
	
			while 1 {
				set dir [tk_chooseDirectory \
						-initialdir $DefProjDir \
						-parent . \
						-title "Project directory"]

				if { $dir == "" } {
					# cancelled
					return
				}

				set dir [file normalize $dir]

				if ![val_prj_dir $dir] {
					# formally illegal
					continue
				}

				if { [val_prj_exists $dir] > 0 } {
					break
				}
			}
		}

	} else {

		while 1 {

			set dir [lindex $LProjects $which]
			if { $dir == "" } {
				alert "No such project"
				break
			}

			set dir [file normalize $dir]

			if ![val_prj_dir $dir] {
				set dir ""
				break
			}

			if { [val_prj_exists $dir] <= 0 } {
				set dir ""
			}
			break
		}

		if { $dir == "" } {
			# cannot open, remove the entry from LProjects
			set LProjects [lreplace $LProjects $which $which]
			upd_last_project_list
			return
		}
	}

	# add to LProjects

	set lp ""
	lappend lp $dir
	set nc 1
	foreach p $LProjects {
		if { $nc >= 6 } {
			# no more than 6
			break
		}
		if { $p == "" } {
			continue
		}
		set p [file normalize $p]
		if { $p == $dir } {
			continue
		}
		lappend lp $p
		incr nc
	}
	set LProjects $lp
	upd_last_project_list
	setup_project
	reset_bnx_menus
	reset_file_menu
}

proc new_project { } {
#
# Initializes a directory for a new project
#
	global P DefProjDir

	if [close_project] {
		# cancelled 
		return
	}

	while 1 {
		# select the directory
		set dir [tk_chooseDirectory -initialdir $DefProjDir \
			-title "Select directory for the project:"]
		if { $dir == "" } {
			# cancelled
			return
		}

		# check if this is a proper subdirectory of DefProjDir
		set dir [file normalize $dir]

		if ![val_prj_dir $dir] {
			continue
		}

		set v [val_prj_exists $dir 2]

		if { $v > 0 } {
			# this is an existing project
			if [confirm "Directory $dir contains something that\
				looks like an existing project. Would you like\
				to open that project?"] {

				open_project -1 $dir
				return
			}

			# keep trying
			continue
		}

		if { $v < 0 } {
			if ![confirm "Directory $dir is not empty! Do you want\
				to erase its contents? THIS CANNOT BE\
				UNDONE!!!"] {

				continue
			}

			# we remove the directory and create it from scratch
			log "Erase directory: $dir"
			if {
			   [catch { file delete -force -- $dir } err] ||
			   [catch { file mkdir $dir } err] } {
				alert "Remove failed: $err"
				continue
			}
		}

		break
	}

	# we have agreed on the directory, now select the praxis type, i.e.,
	# single-program/multiple program; options:
	#
	# single:   single program, create app.cc + options.sys
	# multiple: specify suffixes, create multiple app_xxx.cc and
	#           options_xxx.sys files

	mk_project_selection_window

	while 1 {

		set ev [md_wait]

		if { $ev < 0 } {
			# cancellation
			return
		}
		if { $ev == 1 } {
			# single program
			set md ""
			break
		}
		if { $ev == 2 } {
			# multiple programs, validate the tags
			set md ""
			set er ""
			set ec 0
			for { set i 0 } { $i < 8 } { incr i } {
				set t $P(MW,E$i)
				if { $t == "" } {
					continue
				}
				if ![regexp -nocase "^\[a-z0-9\]+$" $t] {
					append er ", illegal tag $t"
					incr ec
					continue
				}
				if { [lsearch -exact $md $t] >= 0 } {
					append er ", duplicate tag $t"
					incr ec
					continue
				}
				lappend md $t
			}
			if { $md == "" && $ec == 0 } {
				set ec 1
				", no tags specified"
			}
			if $ec {
				if { $ec > 1 } {
					set ec "Errors:"
				} else {
					set ec "Error:"
				}
				alert "$ec [string range $er 2 end]"
				continue
			}
			# OK
			break
		}
	}

	md_stop

	# done: create placeholder files

	set flist [list "options.sys"]

	if { $md != "" } {
		foreach m $md {
			lappend flist "app_${m}.cc"
			lappend flist "options_${m}.sys"
		}
	} else {
		lappend flist "app.cc"
	}

	foreach m $flist {

		if [regexp "cc$" $m] {
			set fc "#include \"sysio.h\"\n\n"
			append fc "// This is $m\n\n"
			append fc "fsm root {\n\tentry INIT:\n\n}"
		} else {
			set fc "// This is $m (initially empty)"
		}

		set tf [file join $dir $m]
		log "Creating file: $tf"
		if [catch { open $tf "w" } fd] {
			alert "Cannot open $tf for writing"
			return
		}
		if [catch { puts $fd $fc } md] {
			alert "Cannot write to $tf: $md"
			catch { close $fd }
			return
		}
		catch { close $fd }
	}

	# now open as a ready project
	open_project -1 $dir
}

proc mk_project_selection_window { } {
#
# Opens a dialog to select the project type
#
	global P

	set w [md_window "Project type"]

	frame $w.lf
	pack $w.lf -side left -expand y -fill y

	button $w.lf.b -text "Single program" \
		-command "md_click 1"
	pack $w.lf.b -side top -expand n -fill x

	button $w.lf.c -text "Cancel" \
		-command "md_click -1"
	pack $w.lf.c -side bottom -expand n -fill x

	set f $w.rf

	frame $f
	pack $f -side right -expand y -fill x

	button $f.b -text "Multiple programs" \
		-command "md_click 2"
	pack $f.b -side top -expand y -fill x

	for { set i 0 } { $i < 8 } { incr i } {
		# the tags
		set tf $f.f$i
		frame $tf
		pack $tf -side top -expand y -fill x
		label $tf.l -text "Tag $i: "
		pack $tf.l -side left -expand n
		set P(MW,E$i) ""
		entry $tf.e -width 8 -font {-family courier -size 10} \
			-textvariable P(MW,E$i)
		pack $tf.e -side left -expand y -fill x
	}

	bind $w <Destroy> "md_click -1"
}

proc get_config { } {
#
# Reads the project configuration from config.prj
#
	global CFItems P

	# start from the dictionary of defaults
	set P(CO) $CFItems

	if [catch { open "config.prj" "r" } fd] {
		return
	}

	if [catch { read $fd } pf] {
		catch { close $fd }
		alert "Cannot read config.prj: $pf"
		return
	}

	catch { close $fd }

	set D [dict create]

	foreach { k v } $pf {
		if { $k == "" || ![dict exists $P(CO) $k] } {
			alert "Illegal contents of config.prj ($vp), file\
				ignored"
			return
		}
		dict set D $k $v
	}

	set P(CO) [dict merge $P(CO) $D]
}

proc set_config { } {
#
# Saves the project configuration
#
	global P

	if [catch { open "config.prj" "w" } fd] {
		alert "Cannot open config.prj for writing: $fd"
		return
	}

	if [catch { puts -nonewline $fd $P(CO) } er] {
		catch { close $fd }
		alert "Cannot write to config.prj: $er"
		return
	}

	catch { close $fd }
}

proc setup_project { } {
#
# Set up the project's parameters and build the dynamic menus; assumes we are
# in the project's directory
#
	global P

	get_config
	set P(AC) 1

	# enable menus ....
}

###############################################################################

proc set_menu_button { w tx ltx cmd } {
#
# Set up a menu button with some initial text tx and the list of options ltx
#
	if { [lsearch -exact $ltx $tx] < 0 } {
		set tx "---"
	}

	menubutton $w -text $tx -direction right -menu $w.m -relief raised
	menu $w.m -tearoff 0

	set n 0
	foreach t $ltx {
		$w.m add command -label $t -command "$cmd $w $n"
		incr n
	}
}

proc board_list { cpu } {

	global PicOSPath

	set dn [file join $PicOSPath PicOS $cpu BOARDS]
	set fl [glob -nocomplain -tails -directory $dn *]

	set r ""
	foreach f $fl {
		if [file isdirectory [file join $dn $f]] {
			lappend r $f
		}
	}
	return [lsort $r]
}

proc do_board_selection { } {
#
# Execute CPU and board selection from Configuration menu
#
	global P CFBoardItems

	if !$P(AC) {
		return
	}

	params_to_dialog $CFBoardItems

	while 1 {

		# have to redo this in the loop as the layout of the window
		# may change
		mk_board_selection_window

		set ev [md_wait]

		if { $ev < 0 } {
			# cancellation
			reset_build_menu
			return
		}
		if { $ev == 1 } {
			# accepted; copy the options
			dialog_to_params $CFBoardItems
			md_stop
			set_config
			reset_build_menu
			return
		}
		# redo
	}
}

proc cpu_selection_click { w n } {
#
# A different CPU has been selected
#
	global P CPUTypes

	set t [$w.m entrycget $n -label]
	$w configure -text $t
	set P(MW,CPU) $t
}

proc board_selection_click { w n } {
#
# A board has been selected
#
	global P

	# the board number
	set nb 0
	regexp "\[0-9\]+$" $w nb

	set t [$w.m entrycget $n -label]
	$w configure -text $t

	set P(MW,BO) [lreplace $P(MW,BO) $nb $nb $t]
}

proc mk_board_selection_window { } {
#
# Open the board selection window
#
	global P CPUTypes

	set w [md_window "Board selection"]

	set f "$w.main"

	frame $f
	pack $f -side top -expand y -fill both

	# column number for the grid
	set cn 0
	set rn 0

	### CPU selection #####################################################

	set rm [expr $rn + 1]

	label $f.cpl -text "CPU"
	grid $f.cpl -column $cn -row $rn -sticky nw -padx 1 -pady 1

	set_menu_button $f.cpb $P(MW,CPU) $CPUTypes cpu_selection_click
	grid $f.cpb -column $cn -row $rm -sticky nw -padx 1 -pady 1

	### Multiple boards/single board ######################################

	if { $P(PL) != "" } {
		# we have a multi-program case, so the "Multiple" checkbox
		# is needed
		incr cn
		label $f.mbl -text "Multiple"
		grid $f.mbl -column $cn -row $rn -sticky nw -padx 1 -pady 1
		checkbutton $f.mbc -variable P(MW,MB) \
			-command "md_click 2"
		grid $f.mbc -column $cn -row $rm -sticky nw -padx 1 -pady 1
	}

	# the list of available boards
	set boards [board_list $P(MW,CPU)]

	if $P(MW,MB) {
		# multiple
		set nb 0
		set tb ""
		set lb ""
		foreach suf $P(PL) {
			set bn [lindex $P(MW,BO) $nb]
			if { $bn == "" } {
				if { $lb != "" } {
					set bn $lb
				} else {
					set bn "---"
				}
			} else {
				set lb $bn
			}
			incr cn
			label $f.bl$nb -text "Board ($suf)"
			grid $f.bl$nb -column $cn -row $rn -sticky nw \
				-padx 1 -pady 1
			set_menu_button $f.bm$nb $bn $boards \
				board_selection_click
			grid $f.bm$nb -column $cn -row $rm -sticky nw \
				-padx 1 -pady 1
			incr nb
			lappend tb $bn
		}
		set P(MW,BO) $tb
	} else {
		# single board
		incr cn
		set bn [lindex $P(MW,BO) 0]
		label $f.bl0 -text "Board"
		grid $f.bl0 -column $cn -row $rn -sticky nw -padx 1 -pady 1
		set_menu_button $f.bm0 $bn $boards board_selection_click
		grid $f.bm0 -column $cn -row $rm -sticky nw -padx 1 -pady 1
	}

	incr cn

	# the done button
	button $f.don -text "Done" -width 7 \
		-command "md_click 1"
	grid $f.don -column $cn -row $rn -sticky nw -padx 1 -pady 1

	button $f.can -text "Cancel" -width 7 \
		-command "md_click -1"
	grid $f.can -column $cn -row $rm -sticky nw -padx 1 -pady 1

	bind $w <Destroy> "md_click -1"
}
	
proc terminate { { f "" } } {

	global REX

	if $REX { return }

	set REX 1

	if { $f == "" && [edit_unsaved] } {
		return
	}

	edit_kill
	abort_term
	stop_piter
	stop_genimage
	stop_udaemon
	bpcs_kill "FL"
	close_project
	exit 0
}

###############################################################################

proc params_to_dialog { nl } {
#
# Copy relevant configuration parameters to dialog variables ...
#
	global P

	foreach { k j } $nl {
		set P(MW,$k) [dict get $P(CO) $k]
	}
}

proc dialog_to_params { nl } {
#
# ... and the other way around
#
	global P

	foreach { k j } $nl {
		dict set P(CO) $k $P(MW,$k)
	}
}

###############################################################################

proc do_loaders_config { } {

	global P CFLoadItems CFLDNames

	if !$P(AC) {
		return
	}

	# make sure the loader is not active while we are doing this
	if [stop_loader 1] {
		# the user says "NO"
		return
	}

	params_to_dialog $CFLoadItems

	mk_loaders_conf_window

	while 1 {

		set ev [md_wait]

		if { $ev < 0 } {
			# cancelled
			return
		}

		if { $ev == 1 } {
			# accepted
			dialog_to_params $CFLoadItems
			md_stop
			set_config
			return
		}
	}
}

proc mk_loaders_conf_window { } {

	global P ST

	set w [md_window "Loader configuration"]

	## Elprotronic
	set f $w.f0
	labelframe $f -text "Elprotronic" -padx 2 -pady 2
	pack $f -side top -expand y -fill x

	if { $P(MW,LDSEL) == "" } {
		if { $ST(SYS) == "L" } {
			set ds "MGD"
		} else {
			set ds "ELP"
		}
		set P(MW,LDSEL) $ds
	}

	radiobutton $f.sel -text "Use" -variable P(MW,LDSEL) -value "ELP"
	pack $f.sel -side top -anchor "nw"
	frame $f.f
	pack $f.f -side top -expand y -fill x
	label $f.f.l -text "Path to the program's executable: "
	pack $f.f.l -side left -expand n
	button $f.f.b -text "Select" -command "loaders_conf_elp_fsel"
	pack $f.f.b -side right -expand n
	label $f.f.f -textvariable P(MW,LDELPPATH)
	pack $f.f.f -side right -expand n

	## MSP430GDB
	set f $w.f1
	labelframe $f -text "msp430-gdb" -padx 2 -pady 2
	pack $f -side top -expand y -fill x
	radiobutton $f.sel -text "Use" -variable P(MW,LDSEL) -value "MGD"
	pack $f.sel -side top -anchor "nw"
	frame $f.f
	pack $f.f -side top -expand y -fill x
	label $f.f.l -text "FET device for msp430-gdbproxy: "
	pack $f.f.l -side left -expand n
	button $f.f.b -text "Select" -command "loaders_conf_mgd_fsel"
	pack $f.f.b -side right -expand n
	label $f.f.f -textvariable P(MW,LDMGDDEV)
	pack $f.f.f -side right -expand n
	frame $f.g
	pack $f.g -side top -expand y -fill x
	label $f.g.l -text "Arguments to msp430-gdbproxy: "
	pack $f.g.l -side left -expand n
	entry $f.g.e -width 16 -font {-family courier -size 10} \
		-textvariable P(MW,LDMGDARG)
	pack $f.g.e -side right -expand n

	## Buttons
	set f $w.fb
	frame $f
	pack $f -side top -expand y -fill x
	button $f.c -text "Cancel" -command "md_click -1"
	pack $f.c -side left -expand n
	button $f.d -text "Done" -command "md_click 1"
	pack $f.d -side right -expand n
}

proc loaders_conf_elp_fsel { } {
#
# Select the path to Elprotronic loader
#
	global P ST env

	if { $ST(SYS) == "L" } {
		alert "You cannot configure this loader on Linux"
		return
	}

	if [info exists P(MW,LDELPPATH_D)] {
		set id $P(MW,LDELPPATH_D)
	} else {
		set id ""
		if { $P(MW,LDELPPATH) == "" } {
			if [info exists env(PROGRAMFILES)] {
				set fp $env(PROGRAMFILES)
			} else {
				set fp "C:/Program Files"
			}
			if [file isdirectory $fp] {
				set id $fp
			}
		} else {
			# use the directory path of last selection
			set fp [file dirname $P(MW,LDELPPATH)]
			if [file isdirectory $fp] {
				set id $fp
			}
		}
		set P(MW,LDELPPATH_D) $id
	}

	set fi [tk_getOpenFile \
		-initialdir $id \
		-filetype [list [list "Executable" [list ".exe"]]] \
		-defaultextension ".exe" \
		-parent $P(MW,WI)]

	if { $fi != "" } {
		set P(MW,LDELPPATH) $fi
	}
}

proc loaders_conf_mgd_fsel { } {
#
# Select the path to mspgcc-gdb (gdb proxy) device
#
	global P ST

	if { $ST(SYS) != "L" } {
		alert "This loader can only be configured on Linux"
		return
	}

	set id "/dev"
	if { $P(MW,LDMGDDEV) != "" } {
		set fp [file dirname $P(MW,LDMGDDEV)]
		if [file isdirectory $fp] {
			set id $fp
		}
	}

	set fi [tk_getOpenFile \
		-initialdir $id \
		-parent $P(MW,WI)]

	if { $fi != "" } {
		set P(MW,LDMGDDEV) $fi
	}
}

proc do_vuee_config { } {

	global P CFVueeItems

	if !$P(AC) {
		return
	}

	params_to_dialog $CFVueeItems

	mk_vuee_conf_window

	while 1 {

		set ev [md_wait]

		if { $ev < 0 } {
			# cancelled
			return
		}

		if { $ev == 1 } {
			# accepted
			dialog_to_params $CFVueeItems
			md_stop
			set_config
			return
		}
	}
}

proc mk_vuee_conf_window { } {

	global P

	set w [md_window "VUEE configuration"]

	##
	set f $w.tf
	frame $f
	pack $f -side top -expand y -fill x
	label $f.l -text "Compile all functions as idiosyncratic: "
	pack $f.l -side left -expand n
	checkbutton $f.c -variable P(MW,CMPIS)
	pack $f.c -side right -expand n

	##
	set f $w.tg
	frame $f
	pack $f -side top -expand y -fill x
	label $f.l -text "Always run with udaemon: "
	pack $f.l -side left -expand n
	checkbutton $f.c -variable P(MW,UDON)
	pack $f.c -side right -expand n

	##
	set f $w.th
	frame $f
	pack $f -side top -expand y -fill x
	label $f.l -text "Praxis data file: "
	pack $f.l -side left -expand n
	button $f.b -text "Select" -command "vuee_conf_fsel VUDF"
	pack $f.b -side right -expand n
	label $f.f -textvariable P(MW,VUDF)
	pack $f.f -side right -expand n

	##
	set f $w.ti
	frame $f
	pack $f -side top -expand y -fill x
	label $f.l -text "Udaemon geometry file: "
	pack $f.l -side left -expand n
	button $f.b -text "Select" -command "vuee_conf_fsel UDDF"
	pack $f.b -side right -expand n
	label $f.f -textvariable P(MW,UDDF)
	pack $f.f -side right -expand n

	##
	set f $w.tj
	frame $f
	pack $f -side top -expand y -fill x
	button $f.c -text "Cancel" -command "md_click -1"
	pack $f.c -side left -expand n
	button $f.d -text "Done" -command "md_click 1"
	pack $f.d -side right -expand n
}

proc vuee_conf_fsel { tp } {
#
# Selects a data file for the praxis (VUEE model) or udaemon
#
	global P

	if { ![info exists P(LFS,$tp)] || ![inside_project $P(LFS,$tp)] } {
		# remembers last directory and defaults to the project's
		# directory
		set P(LFS,$tp) [pwd]
	}

	if { $tp == "UDDF" } {
		set ft [list [list "Udaemon geometry file" [list ".geo"]]]
		set de ".geo"
		set ti "geometry file for udaemon"
	} else {
		set ft [list [list "Praxis data file" [list ".xml"]]]
		set de ".xml"
		set ti "data file for the praxis"
	}

	while 1 {

		set fn [tk_getOpenFile 	-defaultextension $de \
					-filetypes $ft \
					-initialdir $P(LFS,$tp) \
					-title "Select a $ti" \
					-parent $P(MW,WI)]

		if { $fn == "" } {
			# cancelled
			return
		}

		# check if OK
		if ![inside_project $fn] {
			alert "The file must belong to the project tree"
			continue
		}

		if ![file isfile $fn] {
			alert "The file doesn't exist"
			continue
		}

		# assume it is OK, but use a relative path
		set P(MW,$tp) [relative_path $fn]

		# for posterity
		set P(LS,$tp) [file dirname $fn]

		return
	}
}

###############################################################################

proc bpcs_run { path pi } {
#
# Run a background (Windows?) program
#
	global TCMD

	# a simple escape; do we need more?
	regsub -all "\[ \t\]" $path {\\&} path
	log "Running $path <$pi>"

	if [catch { exec bash -c "exec $path" & } pl] {
		alert "Cannot execute $path: $pl"
		return 1
	}

	log "Process ID: $pl"

	set TCMD($pi) $pl
	if { $TCMD($pi,AC) != "" } {
		$TCMD($pi,AC)
	}

	bpcs_check $pi
	return 0
}

proc bpcs_check { pi } {
#
# Checks for the presence of a background process
#
	global TCMD

	if { $TCMD($pi) == "" } {
		set TCMD($pi,CB) ""
		return
	}

	if [catch { exec kill -0 $TCMD($pi) } ] {
		# gone
		log "Background process $TCMD($pi) gone"
		set TCMD($pi) ""
		set TCMD($pi,CB) ""
		if { $TCMD($pi,AC) != "" } {
			$TCMD($pi,AC)
		}
		return
	}

	set TCMD($pi,CB) [after 1000 "bpcs_check $pi"]
}

proc bpcs_kill { pi } {
#
# Kills a background process (monitored by a callback)
#
	global TCMD

	if { $TCMD($pi) == "" } {
		set TCMD($pi,CB) ""
		return
	}

	if [catch { exec kill -$TCMD($pi,SI) $TCMD($pi) } err] {
		# something wrong?
		log "Cannot kill process $TCMD($pi): $err"
	}

	set TCMD($pi) ""
	if { $TCMD($pi,CB) != "" } {
		catch { after cancel $TCMD($pi,CB) }
		set TCMD($pi,CB) ""
	}
	if { $TCMD($pi,AC) != "" } {
		# action after kill
		catch { $TCMD($pi,AC) }
	}
}

###############################################################################

proc run_genimage { } {
#
	global P TCMD

	if { !$P(AC) || $P(CO) == "" } {
		# no project
		return
	}

	if { $TCMD(FG) != "" } {
		if !$auto {
			alert "Genimage appears to be running already"
		}
		return
	}

	set ef [auto_execok "genimage"]
	if { $ef == "" } {
		alert "Cannot start genimage: not found on the PATH"
		return
	}

	if [file executable $ef] {
		set cmd "[list $ef]"
	} else {
		set cmd "[list sh] [list $ef]"
	}

	append cmd " -C 2>@1"

	if [catch { open "|$cmd" "r" } fd] {
		alert "Cannot start genimage: $fd"
		return
	}

	set TCMD(FG) $fd
	reset_exec_menu

	# nothing will ever arrive on this pipe; we use it to
	# find out when the script exits
	fconfigure $fd -blocking 0 -buffering none
	fileevent $fd readable "genimage_pipe_event"
}

proc genimage_pipe_event { } {
#
# Detect when the script exits
#
	global TCMD

	if { [catch { read $TCMD(FG) } dummy] || [eof $TCMD(FG)] } {
		stop_genimage
	}
}

proc stop_genimage { } {
#
	global TCMD

	if { $TCMD(FG) != "" } {
		kill_pipe $TCMD(FG)
		set TCMD(FG) ""
		# may fail if we have closed the main window already
		catch { reset_exec_menu }
	}
}

###############################################################################

proc run_udaemon { { auto 0 } } {
#
	global P TCMD

	if { !$P(AC) || $P(CO) == "" } {
		# no project
		return
	}

	if { $TCMD(FU) != "" } {
		if !$auto {
			alert "Udaemon appears to be running already"
		}
		return
	}

	set ef [auto_execok "udaemon"]
	if { $ef == "" } {
		alert "Cannot start udaemon: not found on the PATH"
		return
	}

	if [file executable $ef] {
		set cmd "[list $ef]"
	} else {
		set cmd "[list sh] [list $ef]"
	}

	# check for the geometry file
	set gf [dict get $P(CO) "UDDF"]

	if { $gf != "" } {
		# there is a geometry file
		if ![file_present $gf] {
			alert "The geometry file $gf doesn't exist"
			return
		}
		append cmd " -G [list $gf]"
	}

	append cmd " 2>@1"

	if [catch { open "|$cmd" "r" } fd] {
		alert "Cannot start udaemon: $fd"
		return
	}

	set TCMD(FU) $fd
	reset_exec_menu

	# nothing will ever arrive on this pipe; we use it to
	# find out when udaemon exits
	fconfigure $fd -blocking 0 -buffering none
	fileevent $fd readable "udaemon_pipe_event"
}

proc udaemon_pipe_event { } {
#
# Detect when udaemon exits
#
	global TCMD

	if { [catch { read $TCMD(FU) } dummy] || [eof $TCMD(FU)] } {
		stop_udaemon
	}
}

proc stop_udaemon { } {
#
	global TCMD

	if { $TCMD(FU) != "" } {
		kill_pipe $TCMD(FU)
		set TCMD(FU) ""
		# may fail if we have closed the main window already
		catch { reset_exec_menu }
	}
}

proc run_vuee { } {
#
# The VUEE model is run as a term program (because it writes to the term
# window), unlike udaemon, which is run independently
#
	global P TCMD SIDENAME

	if { !$P(AC) || $P(CO) == "" } {
		# no project
		return
	}

	if { $TCMD(FD) != "" } {
		# This shouldn't be possible
		alert "Term window busy running a command. Abort it first"
		return
	}

	if ![file_present $SIDENAME] {
		# Nor should this
		alert "No VUEE model executable. Build it first"
		return
	}

	set df [dict get $P(CO) "VUDF"]
	if { $df == "" } {
		alert "No data file specified for the model. Configure VUEE\
			first"
		return
	}

	# check if the data file exists
	if ![file_present $df] {
		alert "The data file $df does not exist"
		return
	}

	# We seem to be in the clear
	if [catch { run_term_command "./$SIDENAME" [list $df "+"] } err] {
		alert "Cannot start the model: $err"
		return
	}

	stop_udaemon
	delay 500

	# check if should start udaemon
	set uf [dict get $P(CO) "UDON"]

	if { $uf && $TCMD(FU) == "" } {
		run_udaemon 1
	}
}

proc run_term_command { cmd al } {
#
# Run a command in term window
#
	global TCMD

	if { $TCMD(FD) != "" } {
		error "Already running a command. Abort it first"
	}

	set ef [auto_execok $cmd]
	if { $ef == "" } {
		error "Cannot execute $cmd"
	}

	if [file executable $ef] {
		set cmd "[list $ef]"
	} else {
		set cmd "[list sh] [list $ef]"
	}

	foreach a $al {
		append cmd " [list $a]"
	}

	# stderr to stdout
	append cmd " 2>@1"

	if [catch { open "|$cmd" "r" } fd] {
		error "Cannot execute $cmd, $fd"
	}

	# command started
	set TCMD(FD) $fd
	set TCMD(BF) ""
	mark_running 1
	reset_bnx_menus

	fconfigure $fd -blocking 0 -buffering none -eofchar ""
	fileevent $fd readable "term_output"
}

proc kill_pipe { fd { sig "INT" } } {
#
# Kills the process on the other end of our pipe
#
	if { $fd == "" || [catch { pid $fd } pp] || $pp == "" } {
		return
	}
	foreach p $pp {
		log "Killing <$sig> pipe $fd process $p"
		if [catch { exec kill -$sig $p } err] {
			log "Cannot kill $p: $err"
		}
	}
	catch { close $fd }
}

proc abort_term { } {

	global TCMD

	if { $TCMD(FD) != "" } {
		kill_pipe $TCMD(FD)
		set TCMD(FD) ""
		set TCMD(BF) ""
		term_dspline "--ABORTED--"
		mark_running 0
		# may fail if the master window has been destroyed already
		catch { reset_bnx_menus }
	}
}

proc stop_term { } {

	global TCMD

	if { $TCMD(FD) != "" } {
		kill_pipe $TCMD(FD)
		set TCMD(FD) ""
		set TCMD(BF) ""
		reset_bnx_menus
	}
	mark_running 0
	term_dspline "--DONE--"
}

###############################################################################

proc upload_image { } {

	global P CFLDNames TCMD

	if !$P(AC) {
		return
	}

	if { $TCMD(FL) != "" } {
		alert "Loader already open"
		return
	}

	# the loader
	set ul [dict get $P(CO) "LDSEL"]

	if { $ul == "" } {
		alert "Loader not configured"
		return
	}

	if { [lsearch -exact $CFLDNames $ul] < 0 } {
		alert "Loader $ul unknown"
		return
	}

	upload_$ul
}

proc upload_ELP { } {
#
# Elprotronic
#
	global P TCMD

	set cfn "config.ini"

	set ep [dict get $P(CO) "LDELPPATH"]
	if { $ep == "" } {
		alert "Unknown path to Elprotronic loader, please configure"
		return
	}
	if ![file exists $ep] {
		alert "No Elprotronic loader at $ep"
		return
	}

	if { [catch { glob "Image*.a43" } im] || $im == "" } {
		alert "No .a43 (Intel) format image(s) available for upload"
		return
	}

	log "Images: $im"
	# may have to redo this once
	set loc 1
	while 1 {

		# check for a local copy of the configuration file
		if ![file exists $cfn] {
			# absent -> copy from the installation directory
			if [catch { file copy -force -- \
			    [file join [file dirname $ep] $cfn] $cfn } err] {
				alert "Cannot retrieve the configuration file\
					of Elprotronic loader: $err"
				return
			}
			# flag = local copy already fetched from install
			set loc 0
		}

		# try to open the local configuration file
		if [catch { open $cfn "r" } fd] {
			if $loc {
				# redo
				set loc 0
				catch { file delete -force -- $cfn }
				continue
			}
			alert "Cannot open local configuration file of\
				Elprotronic loader: $fd"
			return
		}

		if [catch { read $fd } cf] {
			catch { close $fd }
			if $loc {
				# redo
				set loc 0
				catch { file delete -force -- $cfn }
				continue
			}
			alert "Cannot read local configuration file of\
				Elprotronic loader: $cf"
			return
		}

		catch { close $fd }

		# last file to load
		if ![regexp "CodeFileName\[^\r\n\]*" $cf mat] {
			if $loc {
				# redo
				set loc 0
				catch { file delete -force -- $cfn }
				continue
			}
			alert "Bad format of Elprotronic configuration file"
			return
		}
		break
	}

	# locate the previous parameters
	set loc 0
	if [regexp \
	    "^CodeFileName\[ \t\]+(\[^ \t\]+)\[ \t\]+(\[^ \t\]+)\[ \t\]+(.+)" \
	    $mat jnk suf fil pat] {
		# format OK
		set loc 1
		log "Previous: $suf $fil $pat"
		if { $suf != "a43" || [lsearch -exact $im $fil] < 0 } {
			set loc 0
		}
		# verify the directory
		if { !$loc || [file normalize [string trim $pat]] != \
		     [file normalize [file join [pwd] $fil]] } {
			set loc 0
		}
	}

	if !$loc {
		# have to update the config file
		set im [lindex [lsort $im] 0]
		set ln "CodeFileName\ta43\t${im}\t"
		append ln [file normalize [file join [pwd] $im]]
		# substitute and rewrite
		set ix [string first $mat $cf]
		regsub -all "/" $ln "\\" ln
		log "Substituting: $ln"
		set cf "[string range $cf 0 [expr $ix-1]]$ln[string range $cf \
			[expr $ix + [string length $mat]] end]"

		if [catch { open $cfn "w" } fd] {
			alert "Cannot open the local configuration file of\
				Elprotronic loader for writing: $fd"
			return
		}
		if [catch { puts -nonewline $fd $cf } err] {
			catch { close $fd }
			alert "Cannot write the configuration file of\
				Elprotronic loader: $err"
			return
		}
		catch { close $fd }
	}

	# start the loader

	bpcs_run $ep "FL"
}

proc stop_loader { { ask 0 } } {

	global TCMD

	if { $TCMD(FL) == "" } {
		return 0
	}

	if { $ask && ![confirm "The loader is running. Do you want me to kill\
		it first?"] } {
			return 1
	}

	bpcs_kill "FL"

	return 0
}

###############################################################################

proc run_piter { } {

	global P TCMD

	if !$P(AC) {
		return
	}

	# find the first free slot
	for { set p 0 } { $p < $TCMD(NPITERS) } { incr p } {
		if { $TCMD(PI$p) == "" } {
			break
		}
	}

	if { $p == $TCMD(NPITERS) } {
		# ignore, this should never happen
		alert "No more piters, kill some"
		return
	}

	set ef [auto_execok "piter"]
	if { $ef == "" } {
		alert "Cannot start piter: not found on the PATH"
		return
	}

	if [file executable $ef] {
		set cmd "[list $ef]"
	} else {
		set cmd "[list sh] [list $ef]"
	}

	append cmd " -C config.pit 2>@1"

	if [catch { open "|$cmd" "r" } fd] {
		alert "Cannot start piter: $fd"
		return
	}

	set TCMD(PI$p) $fd
	incr TCMD(CPITERS)
	set TCMD(PI$p,SN) $TCMD(CPITERS)
	reset_exec_menu

	# we may want to show this output?
	fconfigure $fd -blocking 0 -buffering none
	fileevent $fd readable "piter_pipe_event $p"
}

proc piter_pipe_event { p } {

	global TCMD

	if { [catch { read $TCMD(PI$p) } dummy] || [eof $TCMD(PI$p)] } {
		stop_piter $p
	}
}

proc stop_piter { { w "" } } {

	global TCMD

	for { set p 0 } { $p < $TCMD(NPITERS) } { incr p } {
		if { ($w == "" || $p == $w) && $TCMD(PI$p) != "" } {
			kill_pipe $TCMD(PI$p)
			set TCMD(PI$p) ""
			set TCMD(PI$p,SN) 0
			# may fail if we have closed the main window already
			catch { reset_exec_menu }
		}
	}
}
	
###############################################################################

proc reset_file_menu { } {
#
# Create the File menu of the project window; it must be done dynamically,
# because it depends on the list of recently opened projects
#
	global LProjects P

	set m .menu.file

	$m delete 0 end

	$m add command -label "Open project ..." -command "open_project"
	$m add command -label "New project ..." -command "new_project"
	$m add command -label "Clone project ..." -command "clone_project"
	$m add separator

	if { $LProjects != "" } {
		set ix 0
		foreach p $LProjects {
			# this is a full file path, use the last so many
			# characters
			set p [trunc_fname 64 $p]
			$m add command -label $p -command "open_project $ix"
			incr ix
		}
		$m add separator
	}

	$m add command -label "Quit" -command "terminate"
	$m add separator

	if $P(AC) {
		set st "normal"
	} else {
		set st "disabled"
	}

	$m add command -label "Edit" -command open_multiple -state $st
	$m add command -label "Delete" -command delete_multiple -state $st
	$m add command -label "Rename ..." -command "rename_file" -state $st
	$m add command -label "New file ..." -command "new_file" -state $st
	$m add command -label "Copy from ..." -command "copy_file" -state $st
	$m add command -label "New directory ..." -command "new_directory" \
		-state $st
}

proc reset_build_menu { } {
#
# Re-create the build menu; called whenever something has changed that may
# affect some items on the menu
#
	global P TCMD

	set m .menu.build
	if [catch { $m delete 0 end } ] {
		return
	}

	if !$P(AC) {
		# no project
		return
	}

	if { $P(CO) == "" } {
		# no project, no selection, no build
		return
	}

	set mb [dict get $P(CO) "MB"]
	set bo [dict get $P(CO) "BO"]

	if { $mb != "" && $bo != "" } {
		# we do have mkmk
		if $mb {
			set bi 0
			foreach b $bo {
				set suf [lindex $P(PL) $bi]
				$m add command -label \
					"Pre-build $suf (mkmk $b $suf)" \
					-command "do_mkmk_node $bi"
				incr bi
			}
			$m add separator
			set bi 0
			foreach b $bo {
				set suf [lindex $P(PL) $bi]
				set maf "Makefile_$suf"
				if [file_present $maf] {
					set st "normal"
				} else {
					set st "disabled"
				}
				$m add command -label \
					"Build $suf (make -f Makefile_$suf)" \
					-command "do_make_node $bi" -state $st
				incr bi
			}
			$m add separator
		} else {
			$m add command -label "Pre-build (mkmk $bo)" \
				-command "do_mkmk_node"
			if [file_present "Makefile"] {
				set st "normal"
			} else {
				set st "disabled"
			}
			$m add command -label "Build (make)" \
				-command "do_make_node" -state $st
		}
	}

	$m add command -label "VUEE" -command "do_make_vuee"
	$m add separator
	if { $TCMD(FD) != "" } {
		set st "normal"
	} else {
		set st "disabled"
	}
	$m add command -label "Abort" -command "abort_term" -state $st
}

proc reset_exec_menu { } {
#
# Re-create the exec menu
#
	global P SIDENAME TCMD

	set m .menu.exec
	$m delete 0 end

	if { !$P(AC) || [catch { glob "Image*" } im] || $im == "" } {
		set st "disabled"
	} else {
		set st "normal"
	}

	if { $TCMD(FL) == "" } {
		$m add command -label "Upload image ..." \
			-command upload_image -state $st
	} else {
		$m add command -label "Terminate loader" \
			-command "bpcs_kill FL" -state $st
	}

	if { $TCMD(FG) == "" } {
		$m add command -label "Customize image ..." \
			-command run_genimage -state $st
	} else {
		$m add command -label "Stop genimage" -command stop_genimage
	}

	$m add separator

	if { $TCMD(FD) == "" && [file_present $SIDENAME] } {
		set st "normal"
	} else {
		set st "disabled"
	}
	$m add command -label "Run VUEE" -command run_vuee -state $st

	if { $TCMD(FD) == "" } {
		set st "disabled"
	} else {
		set st "normal"
	}
	$m add command -label "Abort" -command "abort_term" -state $st

	$m add separator

	if { !$P(AC) || ![file_present $SIDENAME] } {
		set st "disabled"
	} else {
		set st "normal"
	}

	if { $TCMD(FU) == "" } {
		$m add command -label "Run udaemon" -command run_udaemon \
			-state $st
	} else {
		$m add command -label "Stop udaemon" -command stop_udaemon
	}

	$m add separator

	set f 0
	for { set p 0 } { $p < $TCMD(NPITERS) } { incr p } {
		if { $TCMD(PI$p) == "" } {
			incr f
		}
	}

	if $P(AC) {
		set st "normal"
	} else {
		set st "disabled"
	}

	if $f {
		# room for more piters
		$m add command -label "Start piter" -command run_piter \
			-state $st
	}

	if { $f < $TCMD(NPITERS) } {
		for { set p 0 } { $p < $TCMD(NPITERS) } { incr p } {
			if { $TCMD(PI$p) != "" } {
				$m add command \
					-label "Stop piter $TCMD(PI$p,SN)" \
					-command "stop_piter $p"
			}
		}
	}
}

proc reset_bnx_menus { } {

	reset_build_menu
	reset_exec_menu
}

proc mark_running_tm { } {

	global P TCMD

	set P(SSV) [format "%3d" $TCMD(CL)]
}

proc mark_running { stat } {

	global P TCMD

	if $stat {
		# running
		if { $TCMD(CB) != "" } {
			# the callback is active
			return
		}
		set TCMD(CL) 0
		set P(SSL) "Running: "
		mark_running_tm
		set TCMD(CB) [after 1000 mark_running_cb]
		return
	}

	if { $TCMD(CB) != "" } {
		after cancel $TCMD(CB)
		set TCMD(CB) ""
	}

	set P(SSL) "Idle:"
}

proc mark_running_cb { } {

	global TCMD P

	incr TCMD(CL)
	mark_running_tm
	set TCMD(CB) [after 1000 mark_running_cb]
}

proc mk_project_window { } {

	global P Term

	# no project active
	set P(AC) 0
	# no configuration
	set P(CO) ""

	menu .menu -tearoff 0

	#######################################################################

	set m .menu.file
	menu $m -tearoff 0

	.menu add cascade -label "File" -menu $m -underline 0

	reset_file_menu

	#######################################################################

	set m .menu.config
	menu $m -tearoff 0

	.menu add cascade -label "Configuration" -menu $m -underline 0
	$m add command -label "CPU+Board ..." -command "do_board_selection"
	$m add command -label "VUEE ..." -command "do_vuee_config"
	$m add command -label "Loaders ..." -command "do_loaders_config"

	#######################################################################

	set m .menu.build
	menu $m -tearoff 0

	.menu add cascade -label "Build" -menu $m -underline 0

	#######################################################################

	set m .menu.exec
	menu $m -tearoff 0

	.menu add cascade -label "Execute" -menu $m -underline 0

	#######################################################################

	reset_bnx_menus

	#######################################################################

	. configure -menu .menu

	#######################################################################

	panedwindow .pane
	pack .pane -side top -expand y -fill both

	frame .pane.left
	pack .pane.left -side left -expand y -fill both

	mark_running 0

	frame .pane.left.sf
	pack .pane.left.sf -side top -expand n -fill x

	label .pane.left.sf.ss -textvariable P(SSL) -background white \
		-justify left -anchor w
	pack .pane.left.sf.ss -side left -expand y -fill x

	label .pane.left.sf.sv -textvariable P(SSV) -background white \
		-justify right -anchor e
	pack .pane.left.sf.sv -side right -expand y -fill x

	set cn .pane.left

	#######################################################################

	ttk::treeview $cn.tree 	-columns { filename type } \
				-displaycolumns {} \
				-yscroll "$cn.vsb set" \
				-xscroll "$cn.hsb set" \
				-show tree

	pack $cn.tree -side top -expand y -fill both

	ttk::scrollbar $cn.vsb -orient vertical -command "$cn.tree yview"
	ttk::scrollbar $cn.hsb -orient horizontal -command "$cn.tree xview"

	$cn.tree column \#0 -stretch 1 -width 120

	bind $cn.tree <<TreeviewOpen>> { gfl_open %W [%W focus] }
	bind $cn.tree <<TreeviewClose>> { gfl_close %W [%W focus] }

	lower [ttk::frame $cn.dummy]
	pack $cn.dummy -expand y -fill both
	grid $cn.tree $cn.vsb -sticky nsew -in $cn.dummy
	grid $cn.hsb -sticky nsew -in $cn.dummy
	grid columnconfigure $cn.dummy 0 -weight 1
	grid rowconfigure $cn.dummy 0 -weight 1

	set P(FL) $cn.tree

	bind $P(FL) <Double-1> "open_for_edit %x %y"
	bind $P(FL) <ButtonPress-3> "tree_menu %x %y %X %Y"
	bind $P(FL) <ButtonPress-2> "tree_menu %x %y %X %Y"

	# tags for marking edited files and their status
	$P(FL) tag configure sred -foreground red
	$P(FL) tag configure sgreen -foreground green

	#######################################################################

	set w .pane.right
	frame $w
	pack $w -side right -expand y -fill both -anchor e

	set Term $w.t

	text $Term

	$Term configure \
		-yscrollcommand "$w.scroly set" \
		-setgrid true \
        	-width 80 -height 24 -wrap char \
		-font {-family courier -size 10} \
		-exportselection 1 \
		-state normal

	$Term delete 1.0 end

	scrollbar $w.scroly -command "$w.t yview"
	# scrollbar $w.scrolx -orient horizontal -command "$w.t xview"
	pack $w.scroly -side right -fill y
	# pack $w.scrolx -side bottom -fill x
	pack $Term -expand yes -fill both

	# tag for file line numbers
	$Term tag configure errtag -background gray

	#######################################################################

	bind $Term <ButtonRelease-1> "tk_textCopy $Term"
	bind $Term <Double-1> "do_file_line $Term %x %y"

	#######################################################################

	# make it a paned window, so the tree view area can be easily resized
	.pane add .pane.left .pane.right

	bind . <Destroy> "terminate -force"
}

proc do_mkmk_node { { bi 0 } } {

	global P

	if ![close_modified] {
		return
	}

	set al ""

	set mb [dict get $P(CO) "MB"]
	set bo [dict get $P(CO) "BO"]

	if $mb {
		lappend al [lindex $bo $bi]
		lappend al [lindex $P(PL) $bi]
	} else {
		lappend al $bo
	}

	if [catch { run_term_command "mkmk" $al } err] {
		alert $err
	}
}

proc do_make_node { { bi 0 } } {

	global P

	if ![close_modified] {
		return
	}

	set mb [dict get $P(CO) "MB"]

	set al ""

	if $mb {
		# the index makes sense
		set mf "Makefile_[lindex $P(PL) $bi]"
		lappend al "-f"
		lappend al $mf
	} else {
		set mf "Makefile"
	}

	if ![file_present $mf] {
		alert "No suitable makefile available. You have to pre-build\
			first"
		return
	}

	if [catch { run_term_command "make" $al } err] {
		alert $err
	}
}

proc do_make_vuee { } {

	global P

	if ![close_modified] {
		return
	}

	set i [dict get $P(CO) "CMPIS"]

	if { $i != 0 } {
		set arg "-i"
	} else {
		set arg ""
	}

	if [catch { run_term_command "picomp" $arg } err] {
		alert $err
	}
}

###############################################################################

if { $ST(SYS) != "L" } {
	#
	# Issue a dummy reference to a file path to trigger a possible DOS-path
	# warning, after which things should continue without any further
	# warnings. This first reference must be caught as otherwise it would
	# abort the script.
	#
	catch { exec ls [pwd] }
}
	
###############################################################################

if { $PicOSPath == "" } {
	if [catch { xq picospath } PicOSPath] {
		puts stderr "cannot locate PicOS path: $PicOSPath"
		exit 99
	}
	set PicOSPath [file normalize $PicOSPath]
}
	
if { $DefProjDir == "" } {
	set DefProjDir [file join $PicOSPath Apps VUEE]
}

get_last_project_list

mk_project_window

###############################################################################

vwait forever
