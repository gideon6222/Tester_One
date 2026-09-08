class_name Changelog
extends RefCounted

## What changed, in the player's terms.
##
## The build stamp answers "did my update land". It cannot answer "what is
## actually different", which after a few sessions of work is the question that
## matters more - and a commit log is the wrong shape for it, being written for
## whoever maintains the code.
##
## Rules for entries: describe what the player can now do or see, not what was
## refactored; one line each; newest first. Add this from day one. On an
## earlier game it arrived far too late to be as useful as it should have been.

const VERSION := "0.1.0"

const RELEASES := [
	{
		"version": "0.1.0",
		"date": "2026-09-08",
		"title": "It runs on a phone",
		"notes": [
			"A track, something to dodge, something to collect, and three lives.",
			"Drag to steer.",
		],
	},
]
