#!/bin/sh

test_description='cruft pack related pack-objects tests'

. ./test-lib.sh

objdir=.git/objects
packdir=$objdir/pack

basic_cruft_pack_tests () {
	expire="$1"

	test_expect_success "unreachable loose objects are packed (expire $expire)" '
		git init repo &&
		test_when_finished "rm -fr repo" &&
		(
			cd repo &&

			test_commit base &&
			git repack -Ad &&
			test_commit loose &&

			test-tool chmtime +2000 "$objdir/$(test_oid_to_path \
				$(git rev-parse loose:loose.t))" &&
			test-tool chmtime +1000 "$objdir/$(test_oid_to_path \
				$(git rev-parse loose^{tree}))" &&

			(
				git rev-list --objects --no-object-names base..loose |
				while read oid
				do
					path="$objdir/$(test_oid_to_path "$oid")" &&
					printf "%s %d\n" "$oid" "$(test-tool chmtime --get "$path")" ||
					echo "object list generation failed for $oid"
				done |
				sort -k1
			) >expect &&

			keep="$(basename "$(ls $packdir/pack-*.pack)")" &&
			cruft="$(echo $keep | git pack-objects --cruft \
				--cruft-expiration="$expire" $packdir/pack)" &&
			test-tool pack-mtimes "pack-$cruft.mtimes" >actual &&

			test_cmp expect actual
		)
	'

	test_expect_success "unreachable packed objects are packed (expire $expire)" '
		git init repo &&
		test_when_finished "rm -fr repo" &&
		(
			cd repo &&

			test_commit packed &&
			git repack -Ad &&
			test_commit other &&

			git rev-list --objects --no-object-names packed.. >objects &&
			keep="$(basename "$(ls $packdir/pack-*.pack)")" &&
			other="$(git pack-objects --delta-base-offset \
				$packdir/pack <objects)" &&
			git prune-packed &&

			test-tool chmtime --get -100 "$packdir/pack-$other.pack" >expect &&

			cruft="$(git pack-objects --cruft --cruft-expiration="$expire" $packdir/pack <<-EOF
			$keep
			-pack-$other.pack
			EOF
			)" &&
			test-tool pack-mtimes "pack-$cruft.mtimes" >actual.raw &&

			cut -d" " -f2 <actual.raw | sort -u >actual &&

			test_cmp expect actual
		)
	'

	test_expect_success "unreachable cruft objects are repacked (expire $expire)" '
		git init repo &&
		test_when_finished "rm -fr repo" &&
		(
			cd repo &&

			test_commit packed &&
			git repack -Ad &&
			test_commit other &&

			git rev-list --objects --no-object-names packed.. >objects &&
			keep="$(basename "$(ls $packdir/pack-*.pack)")" &&

			cruft_a="$(echo $keep | git pack-objects --cruft --cruft-expiration="$expire" $packdir/pack)" &&
			git prune-packed &&
			cruft_b="$(git pack-objects --cruft --cruft-expiration="$expire" $packdir/pack <<-EOF
			$keep
			-pack-$cruft_a.pack
			EOF
			)" &&

			test-tool pack-mtimes "pack-$cruft_a.mtimes" >expect.raw &&
			test-tool pack-mtimes "pack-$cruft_b.mtimes" >actual.raw &&

			sort <expect.raw >expect &&
			sort <actual.raw >actual &&

			test_cmp expect actual
		)
	'

	test_expect_success "multiple cruft packs (expire $expire)" '
		git init repo &&
		test_when_finished "rm -fr repo" &&
		(
			cd repo &&

			test_commit reachable &&
			git repack -Ad &&
			keep="$(basename "$(ls $packdir/pack-*.pack)")" &&

			test_commit cruft &&
			loose="$objdir/$(test_oid_to_path $(git rev-parse cruft))" &&

			# generate three copies of the cruft object in different
			# cruft packs, each with a unique mtime:
			#   - one expired (1000 seconds ago)
			#   - two non-expired (one 1000 seconds in the future,
			#     one 1500 seconds in the future)
			test-tool chmtime =-1000 "$loose" &&
			git pack-objects --cruft $packdir/pack-A <<-EOF &&
			$keep
			EOF
			test-tool chmtime =+1000 "$loose" &&
			git pack-objects --cruft $packdir/pack-B <<-EOF &&
			$keep
			-$(basename $(ls $packdir/pack-A-*.pack))
			EOF
			test-tool chmtime =+1500 "$loose" &&
			git pack-objects --cruft $packdir/pack-C <<-EOF &&
			$keep
			-$(basename $(ls $packdir/pack-A-*.pack))
			-$(basename $(ls $packdir/pack-B-*.pack))
			EOF

			# ensure the resulting cruft pack takes the most recent
			# mtime among all copies
			cruft="$(git pack-objects --cruft \
				--cruft-expiration="$expire" \
				$packdir/pack <<-EOF
			$keep
			-$(basename $(ls $packdir/pack-A-*.pack))
			-$(basename $(ls $packdir/pack-B-*.pack))
			-$(basename $(ls $packdir/pack-C-*.pack))
			EOF
			)" &&

			test-tool pack-mtimes "$(basename $(ls $packdir/pack-C-*.mtimes))" >expect.raw &&
			test-tool pack-mtimes "pack-$cruft.mtimes" >actual.raw &&

			sort expect.raw >expect &&
			sort actual.raw >actual &&
			test_cmp expect actual
		)
	'

	test_expect_success "cruft packs tolerate missing trees (expire $expire)" '
		git init repo &&
		test_when_finished "rm -fr repo" &&
		(
			cd repo &&

			test_commit reachable &&
			test_commit cruft &&

			tree="$(git rev-parse cruft^{tree})" &&

			git reset --hard reachable &&
			git tag -d cruft &&
			git reflog expire --all --expire=all &&

			# remove the unreachable tree, but leave the commit
			# which has it as its root tree intact
			rm -fr "$objdir/$(test_oid_to_path "$tree")" &&

			git repack -Ad &&
			basename $(ls $packdir/pack-*.pack) >in &&
			git pack-objects --cruft --cruft-expiration="$expire" \
				$packdir/pack <in
		)
	'

	test_expect_success "cruft packs tolerate missing blobs (expire $expire)" '
		git init repo &&
		test_when_finished "rm -fr repo" &&
		(
			cd repo &&

			test_commit reachable &&
			test_commit cruft &&

			blob="$(git rev-parse cruft:cruft.t)" &&

			git reset --hard reachable &&
			git tag -d cruft &&
			git reflog expire --all --expire=all &&

			# remove the unreachable blob, but leave the commit (and
			# the root tree of that commit) intact
			rm -fr "$objdir/$(test_oid_to_path "$blob")" &&

			git repack -Ad &&
			basename $(ls $packdir/pack-*.pack) >in &&
			git pack-objects --cruft --cruft-expiration="$expire" \
				$packdir/pack <in
		)
	'
}

basic_cruft_pack_tests never
basic_cruft_pack_tests 2.weeks.ago

test_expect_success 'cruft tags rescue tagged objects' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		test_commit packed &&
		git repack -Ad &&

		test_commit tagged &&
		git tag -a annotated -m tag &&

		git rev-list --objects --no-object-names packed.. >objects &&
		while read oid
		do
			test-tool chmtime -1000 \
				"$objdir/$(test_oid_to_path $oid)" || exit 1
		done <objects &&

		test-tool chmtime -500 \
			"$objdir/$(test_oid_to_path $(git rev-parse annotated))" &&

		keep="$(basename "$(ls $packdir/pack-*.pack)")" &&
		cruft="$(echo $keep | git pack-objects --cruft \
			--cruft-expiration=750.seconds.ago \
			$packdir/pack)" &&
		test-tool pack-mtimes "pack-$cruft.mtimes" >actual.raw &&
		cut -f1 -d" " <actual.raw | sort >actual &&

		(
			cat objects &&
			git rev-parse annotated
		) >expect.raw &&
		sort <expect.raw >expect &&

		test_cmp expect actual &&
		cat actual
	)
'

test_expect_success 'cruft commits rescue parents, trees' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		test_commit packed &&
		git repack -Ad &&

		test_commit old &&
		test_commit new &&

		git rev-list --objects --no-object-names packed..new >objects &&
		while read object
		do
			test-tool chmtime -1000 \
				"$objdir/$(test_oid_to_path $object)" || exit 1
		done <objects &&
		test-tool chmtime +500 "$objdir/$(test_oid_to_path \
			$(git rev-parse HEAD))" &&

		keep="$(basename "$(ls $packdir/pack-*.pack)")" &&
		cruft="$(echo $keep | git pack-objects --cruft \
			--cruft-expiration=750.seconds.ago \
			$packdir/pack)" &&
		test-tool pack-mtimes "pack-$cruft.mtimes" >actual.raw &&

		cut -d" " -f1 <actual.raw | sort >actual &&
		sort <objects >expect &&

		test_cmp expect actual
	)
'

test_expect_success 'cruft trees rescue sub-trees, blobs' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		test_commit packed &&
		git repack -Ad &&

		mkdir -p dir/sub &&
		echo foo >foo &&
		echo bar >dir/bar &&
		echo baz >dir/sub/baz &&

		test_tick &&
		git add . &&
		git commit -m "pruned" &&

		test-tool chmtime -1000 "$objdir/$(test_oid_to_path $(git rev-parse HEAD))" &&
		test-tool chmtime -1000 "$objdir/$(test_oid_to_path $(git rev-parse HEAD^{tree}))" &&
		test-tool chmtime -1000 "$objdir/$(test_oid_to_path $(git rev-parse HEAD:foo))" &&
		test-tool chmtime  -500 "$objdir/$(test_oid_to_path $(git rev-parse HEAD:dir))" &&
		test-tool chmtime -1000 "$objdir/$(test_oid_to_path $(git rev-parse HEAD:dir/bar))" &&
		test-tool chmtime -1000 "$objdir/$(test_oid_to_path $(git rev-parse HEAD:dir/sub))" &&
		test-tool chmtime -1000 "$objdir/$(test_oid_to_path $(git rev-parse HEAD:dir/sub/baz))" &&

		keep="$(basename "$(ls $packdir/pack-*.pack)")" &&
		cruft="$(echo $keep | git pack-objects --cruft \
			--cruft-expiration=750.seconds.ago \
			$packdir/pack)" &&
		test-tool pack-mtimes "pack-$cruft.mtimes" >actual.raw &&
		cut -f1 -d" " <actual.raw | sort >actual &&

		git rev-parse HEAD:dir HEAD:dir/bar HEAD:dir/sub HEAD:dir/sub/baz >expect.raw &&
		sort <expect.raw >expect &&

		test_cmp expect actual
	)
'

test_expect_success 'expired objects are pruned' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		test_commit packed &&
		git repack -Ad &&

		test_commit pruned &&

		git rev-list --objects --no-object-names packed..pruned >objects &&
		while read object
		do
			test-tool chmtime -1000 \
				"$objdir/$(test_oid_to_path $object)" || exit 1
		done <objects &&

		keep="$(basename "$(ls $packdir/pack-*.pack)")" &&
		cruft="$(echo $keep | git pack-objects --cruft \
			--cruft-expiration=750.seconds.ago \
			$packdir/pack)" &&

		test-tool pack-mtimes "pack-$cruft.mtimes" >actual &&
		test_must_be_empty actual
	)
'

test_expect_success 'loose objects mtimes upsert others' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		test_commit reachable &&
		git repack -Ad &&
		git branch -M main &&

		git checkout --orphan other &&
		test_commit cruft &&
		# incremental repack, leaving existing objects loose (so
		# they can be "freshened")
		git repack &&

		tip="$(git rev-parse cruft)" &&
		path="$objdir/$(test_oid_to_path "$tip")" &&
		test-tool chmtime --get +1000 "$path" >expect &&

		git checkout main &&
		git branch -D other &&
		git tag -d cruft &&
		git reflog expire --all --expire=all &&

		git repack --cruft -d &&

		mtimes="$(basename $(ls $packdir/pack-*.mtimes))" &&
		test-tool pack-mtimes "$mtimes" >actual.raw &&
		grep "$tip" actual.raw | cut -d" " -f2 >actual &&
		test_cmp expect actual
	)
'

test_expect_success 'expiring cruft objects with git gc' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		test_commit reachable &&
		git branch -M main &&
		git checkout --orphan other &&
		test_commit unreachable &&

		git checkout main &&
		git branch -D other &&
		git tag -d unreachable &&
		# objects are not cruft if they are contained in the reflogs
		git reflog expire --all --expire=all &&

		git rev-list --objects --all --no-object-names >reachable.raw &&
		git cat-file --batch-all-objects --batch-check="%(objectname)" >objects &&
		sort <reachable.raw >reachable &&
		comm -13 reachable objects >unreachable &&

		# Write a cruft pack containing all unreachable objects.
		git gc --cruft --prune="01-01-1980" &&

		mtimes=$(ls .git/objects/pack/pack-*.mtimes) &&
		test_path_is_file $mtimes &&

		# Prune all unreachable objects from the cruft pack.
		git gc --cruft --prune=now &&

		git cat-file --batch-all-objects --batch-check="%(objectname)" >objects &&

		comm -23 unreachable objects >removed &&
		test_cmp unreachable removed &&
		test_path_is_missing $mtimes
	)
'

test_expect_success 'cruft --local drops unreachable objects' '
	git init alternate &&
	git init repo &&
	test_when_finished "rm -fr alternate repo" &&

	test_commit -C alternate base &&
	# Pack all objects in alternate so that the cruft repack in "repo" sees
	# the object it dropped due to `--local` as packed. Otherwise this
	# object would not appear packed anywhere (since it is not packed in
	# alternate and likewise not part of the cruft pack in the other repo
	# because of `--local`).
	git -C alternate repack -ad &&

	(
		cd repo &&

		object="$(git -C ../alternate rev-parse HEAD:base.t)" &&
		git -C ../alternate cat-file -p $object >contents &&

		# Write some reachable objects and two unreachable ones: one
		# that the alternate has and another that is unique.
		test_commit other &&
		git hash-object -w -t blob contents &&
		cruft="$(echo cruft | git hash-object -w -t blob --stdin)" &&

		( cd ../alternate/.git/objects && pwd ) \
		       >.git/objects/info/alternates &&

		test_path_is_file $objdir/$(test_oid_to_path $cruft) &&
		test_path_is_file $objdir/$(test_oid_to_path $object) &&

		git repack -d --cruft --local &&

		test-tool pack-mtimes "$(basename $(ls $packdir/pack-*.mtimes))" \
		       >objects &&
		! grep $object objects &&
		grep $cruft objects
	)
'

test_expect_success 'MIDX bitmaps tolerate reachable cruft objects' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		test_commit reachable &&
		test_commit cruft &&
		unreachable="$(git rev-parse cruft)" &&

		git reset --hard $unreachable^ &&
		git tag -d cruft &&
		git reflog expire --all --expire=all &&

		git repack --cruft -d &&

		# resurrect the unreachable object via a new commit. the
		# new commit will get selected for a bitmap, but be
		# missing one of its parents from the selected packs.
		git reset --hard $unreachable &&
		test_commit resurrect &&

		git repack --write-midx --write-bitmap-index --geometric=2 -d
	)
'

test_expect_success 'cruft objects are freshend via loose' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		echo "cruft" >contents &&
		blob="$(git hash-object -w -t blob contents)" &&
		loose="$objdir/$(test_oid_to_path $blob)" &&

		test_commit base &&

		git repack --cruft -d &&

		test_path_is_missing "$loose" &&
		test-tool pack-mtimes "$(basename "$(ls $packdir/pack-*.mtimes)")" >cruft &&
		grep "$blob" cruft &&

		# write the same object again
		git hash-object -w -t blob contents &&

		test_path_is_file "$loose"
	)
'

test_expect_success 'gc.recentObjectsHook' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		# Create a handful of objects.
		#
		#   - one reachable commit, "base", designated for the reachable
		#     pack
		#   - one unreachable commit, "cruft.discard", which is marked
		#     for deletion
		#   - one unreachable commit, "cruft.old", which would be marked
		#     for deletion, but is rescued as an extra cruft tip
		#   - one unreachable commit, "cruft.new", which is not marked
		#     for deletion
		test_commit base &&
		git branch -M main &&

		git checkout --orphan discard &&
		git rm -fr . &&
		test_commit --no-tag cruft.discard &&

		git checkout --orphan old &&
		git rm -fr . &&
		test_commit --no-tag cruft.old &&
		cruft_old="$(git rev-parse HEAD)" &&

		git checkout --orphan new &&
		git rm -fr . &&
		test_commit --no-tag cruft.new &&
		cruft_new="$(git rev-parse HEAD)" &&

		git checkout main &&
		git branch -D discard old new &&
		git reflog expire --all --expire=all &&

		# mark cruft.old with an mtime that is many minutes
		# older than the expiration period, and mark cruft.new
		# with an mtime that is in the future (and thus not
		# eligible for pruning).
		test-tool chmtime -2000 "$objdir/$(test_oid_to_path $cruft_old)" &&
		test-tool chmtime +1000 "$objdir/$(test_oid_to_path $cruft_new)" &&

		# Write the list of cruft objects we expect to
		# accumulate, which is comprised of everything reachable
		# from cruft.old and cruft.new, but not cruft.discard.
		git rev-list --objects --no-object-names \
			$cruft_old $cruft_new >cruft.raw &&
		sort cruft.raw >cruft.expect &&

		# Write the script to list extra tips, which are limited
		# to cruft.old, in this case.
		write_script extra-tips <<-EOF &&
		echo $cruft_old
		EOF
		git config gc.recentObjectsHook ./extra-tips &&

		git repack --cruft --cruft-expiration=now -d &&

		mtimes="$(ls .git/objects/pack/pack-*.mtimes)" &&
		git show-index <${mtimes%.mtimes}.idx >cruft &&
		cut -d" " -f2 cruft | sort >cruft.actual &&
		test_cmp cruft.expect cruft.actual &&

		# Ensure that the "old" objects are removed after
		# dropping the gc.recentObjectsHook hook.
		git config --unset gc.recentObjectsHook &&
		git repack --cruft --cruft-expiration=now -d &&

		mtimes="$(ls .git/objects/pack/pack-*.mtimes)" &&
		git show-index <${mtimes%.mtimes}.idx >cruft &&
		cut -d" " -f2 cruft | sort >cruft.actual &&

		git rev-list --objects --no-object-names $cruft_new >cruft.raw &&
		cp cruft.expect cruft.old &&
		sort cruft.raw >cruft.expect &&
		test_cmp cruft.expect cruft.actual &&

		# ensure objects which are no longer in the cruft pack were
		# removed from the repository
		for object in $(comm -13 cruft.expect cruft.old)
		do
			test_must_fail git cat-file -t $object || return 1
		done
	)
'

test_expect_success 'multi-valued gc.recentObjectsHook' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		test_commit base &&
		git branch -M main &&

		git checkout --orphan cruft.a &&
		git rm -fr . &&
		test_commit --no-tag cruft.a &&
		cruft_a="$(git rev-parse HEAD)" &&

		git checkout --orphan cruft.b &&
		git rm -fr . &&
		test_commit --no-tag cruft.b &&
		cruft_b="$(git rev-parse HEAD)" &&

		git checkout main &&
		git branch -D cruft.a cruft.b &&
		git reflog expire --all --expire=all &&

		echo "echo $cruft_a" | write_script extra-tips.a &&
		echo "echo $cruft_b" | write_script extra-tips.b &&
		echo "false" | write_script extra-tips.c &&

		git rev-list --objects --no-object-names $cruft_a $cruft_b \
			>cruft.raw &&
		sort cruft.raw >cruft.expect &&

		# ensure that each extra cruft tip is saved by its
		# respective hook
		git config --add gc.recentObjectsHook ./extra-tips.a &&
		git config --add gc.recentObjectsHook ./extra-tips.b &&
		git repack --cruft --cruft-expiration=now -d &&

		mtimes="$(ls .git/objects/pack/pack-*.mtimes)" &&
		git show-index <${mtimes%.mtimes}.idx >cruft &&
		cut -d" " -f2 cruft | sort >cruft.actual &&
		test_cmp cruft.expect cruft.actual &&

		# ensure that a dirty exit halts cruft pack generation
		git config --add gc.recentObjectsHook ./extra-tips.c &&
		test_must_fail git repack --cruft --cruft-expiration=now -d 2>err &&
		grep "unable to enumerate additional recent objects" err &&

		# and that the existing cruft pack is left alone
		test_path_is_file "$mtimes"
	)
'

test_expect_success 'additional cruft blobs via gc.recentObjectsHook' '
	git init repo &&
	test_when_finished "rm -fr repo" &&
	(
		cd repo &&

		test_commit base &&

		blob=$(echo "unreachable" | git hash-object -w --stdin) &&

		# mark the unreachable blob we wrote above as having
		# aged out of the retention period
		test-tool chmtime -2000 "$objdir/$(test_oid_to_path $blob)" &&

		# Write the script to list extra tips, which is just the
		# extra blob as above.
		write_script extra-tips <<-EOF &&
		echo $blob
		EOF
		git config gc.recentObjectsHook ./extra-tips &&

		git repack --cruft --cruft-expiration=now -d &&

		mtimes="$(ls .git/objects/pack/pack-*.mtimes)" &&
		git show-index <${mtimes%.mtimes}.idx >cruft &&
		cut -d" " -f2 cruft >actual &&
		echo $blob >expect &&
		test_cmp expect actual
	)
'

test_expect_success 'split cruft packs with --max-cruft-size' '
	repo=cruft-with--max-cruft-size &&
	test_when_finished "rm -fr $repo" &&

	git init "$repo" &&

	(
		cd "$repo" &&

		git config core.compression 0 &&

		sz=$((1024 * 1024)) && # 1MiB
		test-tool genrandom foo $sz >foo &&
		test-tool genrandom bar $sz >bar &&
		foo="$(git hash-object -w -t blob foo)" &&
		bar="$(git hash-object -w -t blob bar)" &&

		to=$packdir/pack &&
		# Pack together foo and bar into a single 2MiB pack.
		pack="$(git pack-objects $to <<-EOF
		$foo
		$bar
		EOF
		)" &&

		# Then generate a cruft pack containing foo and bar.
		#
		# Generate the pack with --max-pack-size equal to the
		# size of one object, forcing us to write two cruft
		# packs.
		git pack-objects --cruft --max-pack-size=$sz $to <<-EOF &&
		-pack-$pack.pack
		EOF

		ls $packdir/pack-*.mtimes >crufts &&
		test_line_count = 2 crufts &&

		for cruft in $(cat crufts)
		do
			test-tool pack-mtimes "$(basename "$cruft")" || return 1
		done >actual.raw &&

		cut -d" " -f1 <actual.raw | sort >actual &&
		sort >expect <<-EOF &&
		$foo
		$bar
		EOF

		test_cmp expect actual
	)
'

test_done
