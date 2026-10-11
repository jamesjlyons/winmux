#!/usr/bin/perl
# macOS-only, read-only incident collector. Uses the system Perl and core modules.
# Never copies a profile, raw dump, arbitrary annotation, or raw stack memory.
use strict;
use warnings;
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use Encode qw(decode);
use File::Basename qw(basename);
use Getopt::Long qw(GetOptions);
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use POSIX qw(strftime);

sub read_file {
    my ($path, $limit) = @_;
    open my $file, '<:raw', $path or die "Cannot read input\n";
    my $size = -s $file;
    die "Input exceeds size limit\n" if !defined($size) || $size > $limit;
    local $/;
    return scalar(<$file>) // '';
}
sub file_hash {
    my ($path) = @_;
    open my $file, '<:raw', $path or die "Cannot hash file\n";
    return Digest::SHA->new(256)->addfile($file)->hexdigest;
}
sub utc { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($_[0])); }
sub command {
    my (@args) = @_;
    open my $pipe, '-|', @args or return undef;
    local $/;
    my $value = <$pipe> // '';
    return undef unless close $pipe;
    $value =~ s/\s+\z//;
    return $value;
}

sub summarize_dump {
    my ($bytes) = @_;
    my $address_mask = 281474976710655;  # 48-bit arm64 user-space address.
    my $slice = sub {
        my ($offset, $size) = @_;
        die "Invalid dump bounds\n" if $offset < 0 || $size < 0 || $offset + $size > length($bytes);
        return substr($bytes, $offset, $size);
    };
    my $u32 = sub { unpack('V', $slice->($_[0], 4)) };
    my $u64 = sub { unpack('Q<', $slice->($_[0], 8)) };
    my $string = sub {
        my ($offset, $wide) = @_;
        my $length = $u32->($offset);
        die "Invalid diagnostic string\n" if $length > 16384;
        my $value = $slice->($offset + 4, $length);
        return $wide ? decode('UTF-16LE', $value, Encode::FB_CROAK) : $value;
    };
    die "Not a minidump\n" unless $slice->(0, 4) eq 'MDMP';
    my $count = $u32->(8);
    die "Too many streams\n" if $count > 128;
    my %streams;
    for my $i (0 .. $count - 1) {
        my $entry = $u32->(12) + $i * 12;
        my ($type, $size, $offset) = unpack('V3', $slice->($entry, 12));
        $slice->($offset, $size);
        $streams{$type} = [$offset, $size];
    }
    my %result = (generated_utc => utc($u32->(20)), annotations => {});
    my %allowed = map { $_ => 1 } qw(pid ptype ver plat process_type oom-size gpu-vendor-id gpu-device-id);
    my $take = sub {
        my ($key_offset, $value_offset) = @_;
        my $key = $string->($key_offset, 0);
        return unless $allowed{$key};
        my $value = $string->($value_offset, 0);
        $result{annotations}{$key} = $value if $value =~ /\A[A-Za-z0-9_. ():+-]{1,128}\z/;
    };
    my $dictionary = sub {
        my ($offset) = @_;
        return unless $offset;
        my $n = $u32->($offset);
        die "Too many annotations\n" if $n > 10000;
        for my $i (0 .. $n - 1) {
            $take->($u32->($offset + 4 + $i * 8), $u32->($offset + 8 + $i * 8));
        }
    };
    # Crashpad info and module annotations, using the pinned Crashpad layouts.
    # Only the allowlisted identity/resource values above are emitted.
    if (my $stream = $streams{0x43500001}) {
        my ($offset, $size) = @$stream;
        die "Short Crashpad info\n" if $size < 52;
        $dictionary->($u32->($offset + 40));
        my $list = $u32->($offset + 48);
        if ($list) {
            my $n = $u32->($list);
            die "Too many module annotations\n" if $n > 4096;
            for my $i (0 .. $n - 1) {
                my $module = $u32->($list + 12 + $i * 12);
                $dictionary->($u32->($module + 16));
                my $objects = $u32->($module + 24);
                next unless $objects;
                my $objects_count = $u32->($objects);
                die "Too many annotation objects\n" if $objects_count > 10000;
                for my $j (0 .. $objects_count - 1) {
                    my $entry = $objects + 4 + $j * 12;
                    $take->($u32->($entry), $u32->($entry + 8));
                }
            }
        }
    }
    my @modules;
    if (my $stream = $streams{4}) {
        my $offset = $stream->[0];
        my $n = $u32->($offset);
        die "Too many modules\n" if $n > 4096;
        for my $i (0 .. $n - 1) {
            my $entry = $offset + 4 + $i * 108;
            $slice->($entry, 108);
            my $name = basename($string->($u32->($entry + 20), 1));
            $name =~ s/[^A-Za-z0-9_. ()+-]/_/g;
            my ($cv_size, $cv_offset) = ($u32->($entry + 76), $u32->($entry + 80));
            push @modules, {base => $u64->($entry), size => $u32->($entry + 8), name => $name,
                codeview_header_hex => $cv_size >= 24 ? unpack('H*', $slice->($cv_offset, 24)) : undef};
        }
    }
    # Keep only code addresses that belong to an image; never emit stack bytes.
    my $frame = sub {
        my ($address, $origin) = @_;
        # Strip arm64 pointer authentication/tag bits for user-space images.
        $address &= $address_mask;
        for my $module (@modules) {
            if ($address >= $module->{base} && $address < $module->{base} + $module->{size}) {
                return {image => $module->{name}, image_offset => sprintf('0x%x', $address - $module->{base}),
                    image_base => sprintf('0x%x', $module->{base}), codeview_header_hex => $module->{codeview_header_hex}, origin => $origin};
            }
        }
        return {unmapped => JSON::PP::true, origin => $origin};
    };
    if (my $stream = $streams{6}) {
        my ($offset, $size) = @$stream;
        die "Short exception stream\n" if $size < 168;
        my $tid = $u32->($offset);
        my $n = $u32->($offset + 32);
        die "Invalid exception parameters\n" if $n > 15;
        $result{exception} = {thread_id => $tid, code => sprintf('0x%x', $u32->($offset + 8)),
            flags => sprintf('0x%x', $u32->($offset + 12)),
            parameters => [map { sprintf('0x%x', $u64->($offset + 40 + $_ * 8)) } 0 .. $n - 1]};
        my ($context_size, $context) = ($u32->($offset + 160), $u32->($offset + 164));
        if ($context_size >= 272 && ($u32->($context) & 0x00ff0000) == 0x00400000) {
            my $fp = $u64->($context + 240) & $address_mask;
            my @frames = ($frame->($u64->($context + 264), 'pc'), $frame->($u64->($context + 248), 'lr'));
            if (my $threads = $streams{3}) {
                my $thread_count = $u32->($threads->[0]);
                die "Too many threads\n" if $thread_count > 4096;
                for my $i (0 .. $thread_count - 1) {
                    my $entry = $threads->[0] + 4 + $i * 48;
                    next unless $u32->($entry) == $tid;
                    my ($base, $length, $data) = ($u64->($entry + 24), $u32->($entry + 32), $u32->($entry + 36));
                    $slice->($data, $length);
                    for (1 .. 62) {
                        last if $fp < $base || $fp + 16 > $base + $length || $fp % 8;
                        my $position = $data + $fp - $base;
                        my $next = $u64->($position) & $address_mask;
                        push @frames, $frame->($u64->($position + 8), 'frame_pointer');
                        last if $next <= $fp;
                        $fp = $next;
                    }
                    last;
                }
            }
            $result{arm64_frames} = \@frames;
            $result{stack_method} = 'PC/LR and bounded frame-pointer walk; not a complete symbolicated unwind';
        }
    }
    return \%result;
}

sub main {
    my ($output, $app, $dump);
    GetOptions('output=s' => \$output, 'app=s' => \$app, 'summarize=s' => \$dump) or die "Invalid arguments\n";
    die "Unexpected arguments\n" if @ARGV;
    my $json = JSON::PP->new->utf8->canonical->pretty;
    if ($dump) {
        print $json->encode(summarize_dump(read_file($dump, 64 * 1024 * 1024)));
        return;
    }
    my $home = $ENV{HOME} // die "Missing home directory\n";
    $output //= "$home/Desktop/WinMux-diagnostics-" . strftime('%Y%m%d-%H%M%S', localtime) . ".json";
    my %report = (schema => 1, collected_utc => utc(time), collector_sha256 => file_hash(__FILE__),
        collection => 'Build hashes, system model/version, and up to 20 recent crash summaries. No raw dumps, profiles, URLs, or arbitrary annotations copied. Nothing uploaded.',
        system => {macos => command('/usr/bin/sw_vers', '-productVersion'),
            macos_build => command('/usr/bin/sw_vers', '-buildVersion'),
            model => command('/usr/sbin/sysctl', '-n', 'hw.model'),
            chip => command('/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string'),
            memory_bytes => command('/usr/sbin/sysctl', '-n', 'hw.memsize')},
        bundles => [], crashes => [], warnings => []);
    my $store = "$home/Library/Application Support/WinMux Browser Workspace Alpha";
    my @apps = $app ? ($app) : ();
    if (-f "$store/request.json") {
        my $request = eval { decode_json(read_file("$store/request.json", 65536)) };
        push @apps, $request->{browserPath} if ref($request) eq 'HASH' && $request->{browserPath};
    }
    push @apps, '/Applications/WinMux Browser Alpha.app', "$home/Applications/WinMux Browser Alpha.app";
    my %seen;
    for my $bundle (@apps) {
        next if $seen{$bundle}++ || !-d $bundle;
        my $info = eval { decode_json(command('/usr/bin/plutil', '-convert', 'json', '-o', '-', "$bundle/Contents/Info.plist") // '') };
        next unless ref($info) eq 'HASH' && ($info->{CFBundleIdentifier} // '') eq 'com.jameslyons.winmux.browser.alpha';
        my %hashes;
        for my $pair (
            ['browser', 'Contents/MacOS/Chromium'],
            ['framework', 'Contents/Frameworks/Chromium Framework.framework/Chromium Framework'],
            ['helper', 'Contents/Helpers/WinMux Workspace.app/Contents/MacOS/WinMuxWorkspaceHelper']) {
            $hashes{$pair->[0]} = eval { file_hash("$bundle/$pair->[1]") };
        }
        push @{$report{bundles}}, {name => basename($bundle), version => $info->{CFBundleShortVersionString},
            chromium_revision => $info->{SCMRevision}, sha256 => \%hashes};
    }
    push @{$report{warnings}}, 'No installed or enrolled WinMux Browser Alpha bundle found; pass --app if stored elsewhere.' unless @{$report{bundles}};
    my @roots = ("$home/Library/Application Support/WinMux Browser Alpha/Crashpad",
        "$store/daily/browser-profile/Crashpad");
    my @files;
    for my $root (@roots) {
        for my $folder ('pending', 'completed') {
            my $directory = "$root/$folder";
            next unless -d $directory;
            if (opendir my $dir, $directory) {
                push @files, map { "$directory/$_" } grep { /\A[0-9a-f-]+\.dmp\z/i && -f "$directory/$_" } readdir($dir);
                closedir $dir;
            } else { push @{$report{warnings}}, 'A Crashpad directory could not be read.'; }
        }
    }
    @files = sort { (stat($b))[9] <=> (stat($a))[9] } grep { (stat($_))[9] >= time - 7 * 86400 } @files;
    $report{recent_dump_count} = scalar @files;
    splice(@files, 20) if @files > 20;
    for my $file (@files) {
        my $summary = eval { summarize_dump(read_file($file, 64 * 1024 * 1024)) };
        $summary //= {error => 'Could not parse this dump; raw file retained on this Mac.'};
        $summary->{dump_name} = basename($file);
        $summary->{dump_sha256} = eval { file_hash($file) };
        push @{$report{crashes}}, $summary;
    }
    push @{$report{warnings}}, 'No recent Crashpad dumps found. This does not rule out a killed, hung, or site-error tab.' unless @files;
    sysopen my $dest, $output, O_WRONLY | O_CREAT | O_EXCL, 0600 or die "Cannot create new output file (choose a new --output path)\n";
    print {$dest} $json->encode(\%report) or die "Cannot write report\n";
    close $dest or die "Cannot finish report\n";
    print "Saved diagnostic report: $output\n";
}
main() unless caller;
1;
