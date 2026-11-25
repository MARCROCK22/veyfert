module main

import os
import veyfert
import veyfert.discord
import veyfert.formatter

// Tic-tac-toe with buttons, against another member or against the bot. The bot keeps no
// state: the board travels in the custom IDs of the buttons, so a restart loses no game.
//
// Run it from the folder that contains veyfert:
//   DISCORD_TOKEN=... GUILD_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/tictactoe

// lines are the rows, columns and diagonals that win.
const lines = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2,
	4, 6]]

// Game is a board and its two players. X plays first.
struct Game {
	x discord.Snowflake
	o discord.Snowflake
mut:
	board string = '---------' // nine squares: `-`, `x` or `o`
}

// Game.parse reads the custom ID of a square: `ttt:<x>:<o>:<board>:<square>`.
fn Game.parse(custom_id string) !(Game, int) {
	parts := custom_id.split(':')
	if parts.len != 5 || parts[3].len != 9 {
		return error('not a tic-tac-toe square: ${custom_id}')
	}
	square := parts[4].int()
	if square < 0 || square > 8 {
		return error('not a tic-tac-toe square: ${custom_id}')
	}
	return Game{
		x:     discord.Snowflake.parse(parts[1])!
		o:     discord.Snowflake.parse(parts[2])!
		board: parts[3]
	}, square
}

// turn is the mark that plays next.
fn (g Game) turn() u8 {
	return if g.board.count('x') == g.board.count('o') { `x` } else { `o` }
}

fn (g Game) player(mark u8) discord.Snowflake {
	return if mark == `x` { g.x } else { g.o }
}

// winner is the mark that made a line, or 0.
fn (g Game) winner() u8 {
	for line in lines {
		mark := g.board[line[0]]
		if mark != `-` && mark == g.board[line[1]] && mark == g.board[line[2]] {
			return mark
		}
	}
	return 0
}

fn (g Game) over() bool {
	return g.winner() != 0 || !g.board.contains('-')
}

fn (mut g Game) play(square int) {
	g.board = g.board[..square] + g.turn().ascii_str() + g.board[square + 1..]
}

// best_move is where the bot plays: a square that wins, else one that blocks, else the center,
// a corner or a side.
fn (g Game) best_move() int {
	me := g.turn()
	them := if me == `x` { `o` } else { `x` }
	for mark in [me, them] {
		for line in lines {
			marks := line.map(g.board[it])
			if marks.filter(it == mark).len == 2 && `-` in marks {
				return line[marks.index(`-`)]
			}
		}
	}
	for square in [4, 0, 2, 6, 8, 1, 3, 5, 7] {
		if g.board[square] == `-` {
			return square
		}
	}
	return -1
}

fn (g Game) status() string {
	head := '❌ ${formatter.user_mention(g.x)} vs ⭕ ${formatter.user_mention(g.o)}'
	winner := g.winner()
	if winner != 0 {
		return '${head}\n🏆 ${formatter.user_mention(g.player(winner))} wins!'
	}
	if g.over() {
		return '${head}\nIt is a draw.'
	}
	return '${head}\nTurn: ${formatter.user_mention(g.player(g.turn()))}'
}

// grid is the board as three rows of buttons. Each custom ID carries the whole game.
fn (g Game) grid() []discord.Component {
	over := g.over()
	mut rows := []discord.Component{}
	for row in 0 .. 3 {
		mut squares := []discord.Component{}
		for col in 0 .. 3 {
			square := row * 3 + col
			mark := g.board[square]
			squares << discord.button(
				style:     match mark {
					`x` { .danger }
					`o` { .primary }
					else { .secondary }
				}
				label:     match mark {
					`x` { 'X' }
					`o` { 'O' }
					else { '·' }
				}
				custom_id: 'ttt:${g.x}:${g.o}:${g.board}:${square}'
				disabled:  over || mark != `-`
			)
		}
		rows << discord.action_row(...squares)
	}
	return rows
}

@[veyfert.Declare(name: 'tictactoe', description: 'Plays tic-tac-toe with someone, or with me')]
struct TicTacToe {
mut:
	opponent ?discord.User @[veyfert.Desc: 'Who to play with; me if you pick nobody']
}

fn (t TicTacToe) run(mut ctx veyfert.CommandContext) ! {
	me := ctx.author()
	bot_id := ctx.client.bot_id()!
	mut opponent := bot_id
	if o := t.opponent {
		if o.id == me.id {
			ctx.write(
				content:   'Pick someone else: you cannot play against yourself.'
				ephemeral: true
			)!
			return
		}
		if o.bot && o.id != bot_id {
			ctx.write(content: 'Other bots do not know how to play.', ephemeral: true)!
			return
		}
		opponent = o.id
	}
	game := Game{
		x: me.id
		o: opponent
	}
	ctx.write(
		content:          game.status()
		components:       game.grid()
		allowed_mentions: discord.AllowedMentions{
			users: [opponent] // the challenge pings the opponent, and only them
		}
	)!
}

// Move handles a click on any square of any game.
@[veyfert.CustomIdPrefix('ttt:')]
struct Move {}

fn (m Move) run(mut ctx veyfert.ComponentContext) ! {
	mut game, square := Game.parse(ctx.custom_id)!
	clicker := ctx.author().id
	if clicker != game.x && clicker != game.o {
		ctx.write(content: 'This is not your game. Start one with /tictactoe.', ephemeral: true)!
		return
	}
	if clicker != game.player(game.turn()) {
		ctx.write(content: 'It is not your turn.', ephemeral: true)!
		return
	}
	if game.over() || game.board[square] != `-` {
		ctx.defer_update()!
		return
	}
	game.play(square)
	if game.o == ctx.client.bot_id()! && !game.over() {
		game.play(game.best_move())
	}
	ctx.update(content: game.status(), components: game.grid())!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(TicTacToe{})
	bot.components.add(Move{})
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/tictactoe.json'
	)!
	bot.run()!
}
