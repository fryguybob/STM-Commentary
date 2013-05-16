#!/bin/sh

pandoc -f markdown -t html GHCSTMNotes.md -o ../STM-Commentary-page/index.html --css style.css --standalone