Db = require 'db'
Dom = require 'dom'
Event = require 'event'
Modal = require 'modal'
Obs = require 'obs'
Page = require 'page'
Plugin = require 'plugin'
Server = require 'server'
Social = require 'social'
Time = require 'time'
Ui = require 'ui'
Util = require 'util'
Markdown = require 'markdown'
{tr} = require 'i18n'

handsize = 10
maxtrashcards = 1

exports.render = !->
	if not (+(Db.personal.get 'activity')>=0)
		renderTutorialQuestion()
	else if Db.personal.get('hand').length < handsize and (Db.shared.get 'answerdeck').length > 0
		drawNewAnswerCards()
	else if page = Page.state.get(0)
		if page == 'showhand'
			renderHand()
		else
			round = Db.shared.get 'rounds', page
			if round.phase == 'draw'
				renderInfoBar()
				renderDrawQuestionButton page
			else if round.phase is 'play'
				renderInfoBar()
				playRender page
			else if round.phase is 'vote'
				renderInfoBar()
				voteRender page
			else
				log 'Page:', page
				renderWinnerPage page

			Event.showStar tr 'Round %1', page
			Event.markRead [page]
			renderComments page
	else
		renderInfoBar()
		if Db.shared.get 'paused'
			Dom.text tr('You have run of either answers or questions. Please wait until more have been added, or start a new game!')
		else
			Dom.div !->
				rounds = Db.shared.get 'rounds'
				log 'Rounds', rounds
				Dom.h2 tr 'Active Rounds'
				activeRounds = 0
				Ui.list !->
					Dom.style
						paddingTop: '30px'
						backgroundColor: 'white'
						overflowX: 'hidden'
					for i in [(Object.keys rounds).length - 1..0]
						roundId = Object.keys(rounds)[i]
						if (Db.shared.get 'rounds', roundId, 'phase') in ['draw', 'play', 'vote']
							activeRounds += 1
							renderRoundListItem roundId
				if activeRounds == 0
					Dom.text tr 'Currently no active rounds...'

				Dom.h2 tr 'Finished Rounds'
				Ui.list !->
					Dom.style
						paddingTop: '30px'
						backgroundColor: 'white'
						overflowX: 'hidden'
					for i in [(Object.keys rounds).length - 1 - activeRounds..0]
						roundId = Object.keys(rounds)[i]
						renderRoundListItem roundId

	if (Db.personal.get 'showpatchinfo') == 1
		Modal.show 'New!', !->
			Dom.text tr 'You can now throw away useless cards by tapping \'My Cards\' in the top bar!'
		, !->
			Server.sync 'readPatchNotes'
	else if Db.personal.get('showwinners').length
		popWinnerModal()

renderRoundListItem = (roundId) !->
	round = Db.shared.get 'rounds', roundId
	if round.phase isnt 'unfinished'
		Ui.item !->
			if round.phase in ['play', 'vote', 'done']
				Dom.style
					margin: '-30px -30px 0'
					paddingBottom: '0px'
					position: 'relative'
			
			subtext = null
			highlight = false
			switch(round.phase)
				when 'draw'
					subtext = tr 'Ready to start!'
					break
				when 'play'
					if Db.personal.get 'playedcards', roundId
						subtext = tr 'You played your cards.'
						answers = Db.personal.get 'playedcards', roundId
					else
						subtext = tr 'You still have to play a card!'
						highlight = true
					break
				when 'vote'
					if Db.personal.get 'vote', roundId
						subtext = tr 'You cast your vote.'
						answers = Db.personal.get 'vote', roundId
					else
						subtext = tr 'You still have to vote!'
						highlight = true
					break
				when 'done'
					if round.winner.a.length > 1
						subtext = tr 'And %1 more', round.question.play - 1
					answers = if round.winner then round.winner.a[0] else null
					winners = if round.winner then round.winner.p[0] else null


			if round.phase in ['play', 'vote', 'done']
				renderQuestion
					text: round.question.text
					play: round.question.play
					answers: answers
					winners: winners
					subtext: subtext
					highlight: highlight
					ontapHandler: !->
						Page.nav roundId
					renderBubble: [roundId]
			else
				Dom.div !->
					Dom.style color: '#ba1a6e'
					Dom.text tr 'Ready to start!'
				Dom.onTap !->
					Page.nav roundId

renderInfoBar = !->
	page = Page.state.get(0)
	Dom.div !->
		Dom.style
			display: 'flex'
			height: '45px'
			color: '#666'
			backgroundColor: 'lightgray'
			padding: '0'
			margin: '-6px -8px 5px -8px'
			textAlign: 'center'
			overflow: 'hidden'
			textOverflow: 'ellipsis'
			whiteSpace: 'nowrap'

		Dom.div !->
			Dom.style
				display: 'inline-block'
				fontWeight: 'bold'
				fontSize: '2.2em'
				margin: '3px 0px'
				height: '39px'
				borderRight: '1px solid #bbb'
				flexGrow: '1'
			Dom.text '?'
			Dom.onTap !->
				showHelpPage()

		questionsLeft = (Db.shared.get 'questiondeck').length
		answersLeft = (Db.shared.get 'answerdeck').length
		scores = Db.shared.get 'score'
		if Object.keys(scores).length
			myscore = (0|scores[Plugin.userId()])
			position = 1
			for u, s of scores
				if s != Plugin.userId() and s > myscore
					position++
		else
			position = undefined

		phase_end = 0
		for roundId, round of Db.shared.get 'rounds'
			phase_end = Math.max phase_end, round.phase_end
		Dom.div !->
			Dom.style
				display: 'inline-block'
				fontWeight: 'bold'
				fontSize: '1em'
				margin: '3px 0px'
				height: '39px'
				borderRight: '1px solid #bbb'
				flexGrow: '2'
			Dom.text tr('Time Left')
			Dom.div !->
				Dom.style
					color: '#888'
					fontWeight: 'normal'
				# Time Left is stored per page/round
				Time.deltaText phase_end
			if page
				Dom.onTap !->
					numplayers = (Db.shared.get 'rounds', page, 'waitingfor').length
					waitingtext = if (Db.shared.get 'rounds', page, 'phase') == 'play' then tr('played their cards') else tr('voted')
					Modal.show 'Waiting For', !->
						Dom.div !->
							Dom.text tr('The game will continue ')
							Time.deltaText(Db.shared.get 'rounds', page, 'phase_end')
							Dom.text tr(', or when everyone %1.', waitingtext)
						Dom.div !->
							Dom.style marginTop: '15px'
							Dom.text tr('Still waiting for %1 Players:', numplayers)
						Dom.ul !->
							for userId in Db.shared.get 'rounds', page, 'waitingfor'
								Dom.li !->
									Dom.text Plugin.userName userId
		if not page
			Dom.div !->
				Dom.style
					display: 'inline-block'
					fontWeight: 'bold'
					fontSize: '1em'
					margin: '3px 0px'
					height: '39px'
					borderRight: '1px solid #bbb'
					flexGrow: '2'
				Dom.text tr 'Your Hand'
				Dom.div !->
					Dom.style
						color: '#888'
						fontWeight: 'normal'
					Dom.text tr '%1 cards', (Db.personal.get 'hand').length
				Dom.onTap !->
					Page.nav 'showhand'

		Dom.div !->
			Dom.style
				display: 'inline-block'
				fontWeight: 'bold'
				fontSize: '1em'
				margin: '3px 0px'
				height: '39px'
				flexGrow: '2'
			Dom.text tr('Position')
			Dom.div !->
				Dom.style
					color: '#888'
					fontWeight: 'normal'
				Dom.text if position? then position else 'n/a'
			if position?
				Dom.onTap !->
					Modal.show tr('Score'), !->
						renderScore()

showHelpPage = !->
	Page.nav !->
		Markdown.render """
## Happening against Humanity
Happening against Humanity is a politically very incorrect game that is not suited for children, families, or people who are offended by anything. At all. It is, however, a very fun game to play with some friends who don't care too much about any of that!

## Black and White cards
The game has 2 types of cards: The black (question) cards, and the white (answer) cards.
- After each round, any player can start the next round by drawing a black card. A black card usually has a blank in the question/sentence (\_\_\_\_\_), or is simply a question.
- At the start of the game, everyone gets 10 white cards, and after playing any you can draw white cards until you have a full hand again. You use these white cards to complete or answer the black cards.

## Gameplay
Each round consists of 2 phases: Playing and Voting.

- After a black card has been drawn, everyone plays a white card that he or she thinks is the funniest way to complete or answer the black card.
- After either everyone has played their cards, or a certain time passes, the game moves on to the 'voting round'. During voting, everyone can select his favorite white card(s) from the cards all other players played. The result of the voting is shown after everyone has cast their votes or, again, everyone voted.
- If the black card says 'Play 2', this means that you have to play 2 white cards (in order) to answer or complete the black card.

The game is paused when you run out of either white or black cards. If you want to pause the game at any other moment, simply don't draw new black cards again.

## Inspiration
The game is based on the game 'Cards against Humanity', and uses its original set of cards (with some changes, with thanks to /Pretend You're Xyzzy/), which have been made available to use under the [Attribution-NonCommercial-ShareAlike 3.0 Creative Commons license](http://creativecommons.org/licenses/by-nc-sa/3.0/).

Do you have ideas for more cards? Please suggest them in the support Happening!
"""

renderHand = !->
	Dom.h1 tr 'Your Hand'

	Dom.div !->
		Dom.text tr 'You can select up to %1 card%2 which will be thrown away after this round.', maxtrashcards, if maxtrashcards > 1 then 's' else ''
	if isNewbie()
		Dom.div !->
			Dom.text tr 'It sometimes happens that you have cards you really see no way of using. Each round, you can select up to %1 card%2 to throw away after this round, so that you will get additional new cards in the next round. Note that, if you also played that card in the same round, it will *not* get trashed.', maxtrashcards, if maxtrashcards > 1 then 's' else ''

	trashcards = (Db.personal.get 'trashcards') || []
	for card in Db.personal.get 'hand'
		do (card) !->
			Dom.div !->
				Dom.style marginBottom: '-30px'
				renderCard
					style: if card in trashcards then 'selected' else 'white'
					text: card
					ontapHandler: !->
						Server.sync 'trashcard', card, !->
							if card in trashcards
								r = trashcards.indexOf card
								trashcards.splice r, 1
							else
								if trashcards.length >= maxtrashcards
									trashcards.pop()
								trashcards.push card

							Db.personal.set 'trashcards', trashcards


renderComments = (round) !->
	log 'Rendering comments', round
	Social.renderComments
		path: [round]
		closed: false
		render: (comment) !->
			if comment.s
				Dom.div !->
					Dom.style margin: '6px 0 6px 56px', fontSize: '70%'

					Dom.span !->
						Dom.style color: '#999'
						Time.deltaText comment.t
						Dom.text " • "

					Dom.text comment.c
				return true # We're rendering these type of comments

renderScore = !->
	if Db.shared.get 'score' is {}
		Dom.text tr('No score yet.')
	else
		scores = Db.shared.get 'score'
		sortedUsers = Object.keys(scores).sort (a, b) -> scores[b] - scores[a]
		for userId in sortedUsers
			Dom.div !->
				Dom.text Plugin.userName(userId) + ': ' + scores[userId]

renderWinnerPage = (roundId) !->
	round = Db.shared.get 'rounds', roundId
	winner = round.winner
	Dom.h2 tr('Round %1: %2', roundId, Plugin.userName(winner.p))
	for i in [0..winner.p.length - 1]
		renderQuestion
			text: round.question.text
			play: round.question.play
			answers: winner.a[i]
			winners: winner.p[i]

	renderVoteCount winner

renderVoteCount = (winner) !->
	if winner.v
		Dom.h3 'Votes:'
		log 'winner.v:', winner.v
		Dom.div !->
			for answer, users of winner.v
				log 'answer', JSON.stringify(answer), 'users', JSON.stringify(users)
				answerString = ''
				for i, a of JSON.parse(answer)
					log i, a
					if answerString != ''
						answerString += ', '
					answerString += '*' + a + '*'
				userString = ''
				for u in users
					log u
					if userString != ''
						userString += ', '
					userString += Plugin.userName(u)
				Markdown.render(answerString + ': ' + userString)

popWinnerModal = !->
	roundId = Db.personal.get('showwinners').shift()
	round = Db.shared.get 'rounds', roundId
	winner = round.winner
	question = round.question
	answers = winner.a
	players = winner.p

	winnerString = Util.getWinnerNames(players)

	Modal.show tr('Winner%1 of round %2: %3', (if players.length > 1 then 's' else ''), roundId, winnerString), !->
		Dom.div !->
			Dom.style
				maxHeight: (Dom.viewport.get('height') - 150) + 'px'
				overflow: 'scroll'
			# if isNewbie()
			# 	Dom.div !->
			# 		Dom.text tr 'The winner is decided by the votes. After #TODO write tip'
			log 'question, answer', question, answer
			for i in [0..players.length - 1]
				answer = answers[i]
				player = players[i]
				renderQuestion
					text: question.text
					play: question.play
					answers: answer
					winners: player
			renderVoteCount winner
	, !->
		Server.call 'popShowWinner'

drawNewAnswerCards = !->
	Server.call 'drawcards', (cards) !->
		Modal.show tr('Your new White Card%1', if cards.length > 1 then 's' else ''), !->
			if isNewbie()
				Dom.div !->
					Dom.style
						marginBottom: '25px'
					Dom.h2 tr('Your Hand')
					Dom.text tr('After every round, you will draw new cards for your hand until you hold 10 cards again.')
			for c in cards
				renderCard
					style: 'white'
					text: c

renderDrawQuestionButton = (roundId) !->
	if isNewbie()
		Dom.text tr('Click the button below to start a new round!')

	Ui.bigButton !->
		Dom.text tr('Draw Question')
		Dom.onTap !->
			Server.call 'drawquestion', roundId

playRender = (roundId) !->
	round = Db.shared.get 'rounds', roundId

	if isNewbie()
		Dom.div !->
			Dom.h2 tr('Playing Cards Explained')
			Dom.text tr('Every round starts by one player drawing a question. After that, everyone gets to play one or more cards from their hand. At the end of the round, you will get to vote for who played the best card!')

	question = round.question
	myanswers = Db.personal.get 'playedcards', roundId
	Dom.h1 tr('Play your card%1', if question.play > 1 then 's' else '')

	Dom.h2 tr('Question:')
	log 'Question:'
	log question
	log 'Answers:'
	log myanswers
	renderQuestion
		text: question.text
		play: question.play
		answers: myanswers
	renderCardSelect roundId, question.play

voteRender = (roundId) !->
	round = Db.shared.ref 'rounds', roundId

	if isNewbie()
		Dom.div !->
			Dom.h2 tr('Voting Explained')
			Dom.text tr('After the cards have been played, everyone will get a chance to vote for their favorite card. The card with the most votes will win, and that player will get a point!')

	question = Db.shared.get 'rounds', roundId, 'question'
	vote = Db.personal.get('vote', roundId)

	Dom.h1 tr('Vote for the best card%1', if question.play > 1 then 's' else '')

	if isNewbie()
		Dom.div !->
			Dom.style
				marginBottom: '30px'
			Dom.text tr('Select the card that you think best fills in the blank on the question, or answers the question best/funniest!')

	log 'All:', JSON.stringify(round)
	Dom.div !->
		Dom.style marginTop: '20px'
		for cards in Db.shared.get 'rounds', roundId, 'playedcards'
			log 'Cards:', cards
			do (cards) !->
				log 'Comparing with own', JSON.stringify(cards), JSON.stringify(Db.personal.get 'playedcards', roundId)
				if JSON.stringify(cards) != JSON.stringify(Db.personal.get 'playedcards', roundId)
					log 'Comparing with vote', cards, vote
					Dom.div !->
						selected = JSON.stringify(cards) == JSON.stringify(vote)
						Dom.style
							display: 'inline-block'
							width: '100%'
							marginTop: if question.play > 1 then '20px' else '-20px'
						Dom.div !->
							if question.play > 1 then Dom.style marginTop: '-15px'
							renderQuestion
								text: question.text
								play: question.play
								selected: selected
								answers: cards
								ontapHandler: !->
									log 'Chose', cards, 'as winning card'
									Server.sync 'vote', roundId, cards, !->
										Db.personal.set 'vote', roundId, cards

	if Db.personal.get('playedcards')
		Dom.h2 tr('You Played:')
		if isNewbie()
			Dom.text tr("This is what you played. You can't vote for your own card, though!")
		Dom.div !->
			Dom.style marginTop: '20px'
			renderQuestion
				text: question.text
				play: question.play
				answers: Db.personal.get 'playedcards', roundId

renderTutorialQuestion = !->
	Dom.div !->
		Dom.style
			margin: '50px auto'
			maxWidth: '250px'
			textAlign: 'center'
		if +(Db.personal.get 'activity') < 0
			Dom.text tr("Do you want some hints on how to play the game for the first few rounds anyway?")
			Ui.bigButton tr('Yes'), !->
				Server.call 'tutorialAnswer', 1, 1
			Ui.bigButton tr('No'), !->
				Server.call 'tutorialAnswer', 1, 0
		else
			Dom.text tr("Have you ever played either 'Happening against Humanity', or the card game it is based on, 'Cards against Humanity', before? If not, we can show a few short hints during the game.")
			Ui.bigButton tr('Yes'), !->
				Server.call 'tutorialAnswer', 0, 1
			Ui.bigButton tr('No'), !->
				Server.call 'tutorialAnswer', 0, 0

renderCardSelect = (roundId, numplay) !->
	Obs.observe !->
		log 'Rendering card select'
		hand = Db.personal.ref 'hand'
		if Db.personal.get 'playedcards', roundId
			playedcards = Obs.create(Db.personal.get 'playedcards', roundId)
		else
			playedcards = Obs.create []
		log 'Played Cards', playedcards.get()

		Dom.h2 tr('Your played card%1', if numplay > 1 then 's' else '')

		playcount = playedcards.count()
		for p in [0..numplay-1]
			do (p) !->
				renderCard
					style: 'white'
					text: playedcards.get(p)
					ontapHandler: !->
						cardselectModal numplay, playedcards, hand, (card) !->
							Server.sync 'playcard', roundId, p, card, !->
								for i, c of playedcards.get()
									if c == card
										playedcards.set(i, playedcards.get(p))
								playedcards.set(p, card)

# Opts Values:
# 	text: The text of the question
# 	play: The number of cards that should be played
# 	selected: if the question is selected (default false)
# 	answers: The given answers that are used to fill in the question
# 	ontapHandler: A function that is called when the card is tapped.
# 	winners: Who won this round.
# 	subtext: Additional subtext that is rendered above the winner text
renderQuestion = (opts) !->
	log 'opts', opts
	text = Util.replaceQuestionText opts.text, opts.answers

	subtext = ''
	if opts.subtext
		subtext = opts.subtext + '\r\n'
	
	if opts.winners
		if +opts.winners > 0
			log 'winners is one person', opts.winners
			opts.winners = [opts.winners]

		wincount = 0
		subtext = 'Won by: '
		for w in opts.winners
			if wincount then subtext += ', '
			subtext += Plugin.userName(w)

	text = text.replace(/_/g, '\\_')

	renderCard
		style: (if opts.selected then 'selected' else (if opts.highlight then 'highlight' else 'black'))
		text: text
		ontapHandler: opts.ontapHandler
		play: opts.play
		subtext: subtext
		renderBubble: opts.renderBubble

# Opt Values:
# 	style: black, white, selected (required)
# 	text: The large text that occupies most of the card (required)
# 	ontapHandler: A function that is called when this card is tapped
# 	play: How many cards should be played
# 	compact: Compact style (less padding), boolean
# 	subtext: Smaller text on the bottom of the card
renderCard = (opts) !->
	if opts.style == 'selected'
		black = false
		selected = true
	else
		selected = false
		black = opts.style == 'black'

	if opts.style == 'highlight' then backgroundcolor = 'rgb(0,77,140)'
	else if black then backgroundcolor = 'black'
	else if selected then backgroundcolor = '#ba1a6e'
	else backgroundcolor = 'white'
	textcolor = if (black || selected || opts.style == 'highlight') then 'white' else 'black'

	Dom.div !->
		Markdown.render opts.text || tr('tap to select card')
		if selected || opts.subtext
			Dom.span !->
				Dom.style
					display: 'block'
					marginLeft: '1em'
					marginBottom: '0.5em'
					fontSize: '0.7em'
					fontStyle: 'italic'
				Dom.text (if selected then 'selected' else '') + (opts.subtext||'')
		Dom.style
			position: 'relative'
			fontStyle: if not opts.text then 'italic' else ''
			textAlign: if opts.text then 'left' else 'center'
			backgroundColor: backgroundcolor
			color: textcolor
			margin: '10px auto 0 auto'
			boxShadow: '-3px -2px 10px #aaa, 8px -2px 10px #bbb'
			padding: if opts.compact then '0.5em 1em' else '1em 2em'
			paddingBottom: if selected then '2.0em'
			borderRadius: '15px 15px 0 0'
			fontSize: if Dom.viewport.get('width') > 480 then '1.5em' else '1.2em'
			fontWeight: 'bold'
			minWidth: '255px'
			width: '80%'
			maxWidth: '480px'
			boxSizing: 'border-box'
		if opts.play > 1
			Dom.div !->
				Dom.style
					color: backgroundcolor
					backgroundColor: textcolor
					width: '90px'
					borderRadius: '45px'
					textAlign: 'center'
					position: 'absolute'
					right: '10px'
					bottom: '10px'
				Dom.text 'Play ' + opts.play
		if opts.ontapHandler
			Dom.onTap opts.ontapHandler

		if opts.renderBubble
			Dom.div !->
				Dom.style
					position: 'absolute'
					top: '30px'
					right: '20px'
				Event.renderBubble opts.renderBubble

cardselectModal = (play, selected, cards, handlepick) !->
	Modal.show tr('Your Hand'), !->
		Dom.style
			width: '80%'
		if isNewbie()
			Dom.div !->
				Dom.style
					marginBottom: '30px'
				if Db.personal.get 'activity' > 3 # #moreMagicNumbers
					Dom.text tr 'These are the 10 white (answer) cards you currently have in your hand. After each round, you will draw new cards until you have 10 cards again.'
				else
					Dom.text tr 'If you do not have any cards that you think might win you this round, consider playing some of your worst cards to get new ones next round.'
		Dom.div !->
			Dom.style
				maxHeight: '40%'
				overflow: 'auto'
				_overflowScrolling: 'touch'
				backgroundColor: '#eee'
				margin: '-12px'
				paddingTop: '15px'

			for card in cards.get()
				do (card) !->
					Ui.item !->
						isselected = false
						for i in [0..play-1]
							if selected.get(i) == card
								isselected = true

						Dom.style
							padding: '5px 10px 0 10px'
							marginTop: '-20px'
							textAlign: 'left'
						renderCard
							style: (if isselected then 'selected' else 'white')
							text: card
							compact: true

						Dom.onTap !->
							handlepick card
							Modal.remove()
	, null, ['cancel', "Cancel"]

isNewbie = !->
	activity = Db.personal.get('activity') | 0
	# if Plugin.userName(Plugin.userId()) == 'Erik'
	# 	activity = Math.floor(Math.random() * 8)

	if activity >= 6 # hashtagMagicNumbers
		return false

	if score = Db.shared.get 'score'
		if Plugin.userId() in Object.keys(score)
			return false
	return true

exports.renderSettings = !->
	Dom.div !->
		Markdown.render tr("Disclaimer: If you or anyone else in this group is offended by *anything* at all , then don't install this Group App. This Group App is not suitable for children, families, sensitive people or humanity in general.")

	if Db.shared
		if Plugin.userIsAdmin()
			Dom.h3 !->
				Ui.item !->
					Dom.text tr('(Re)Start Game')
					Dom.onTap !->
						Server.sync 'startgame'
				Ui.item !->
					Dom.text tr 'Advance Round'
					Dom.onTap !->
						Server.sync 'advanceround'
