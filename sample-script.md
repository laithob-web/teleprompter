# Sample interview script

Anything before the first `##` heading is treated as one untitled section.
Delete this preamble and write your own — the format is the whole API.

## Tell me about yourself
<!-- triggers: walk me through your background, introduce yourself, your story, tell us about you -->

I'm a product manager with eight years in fintech, most recently leading the
payments platform team at a company processing about two billion dollars a year.

What I care about is the unglamorous middle of the product — reconciliation,
error states, the paths that only fire two percent of the time but generate
eighty percent of support load. That's where trust in a payments product is
actually won or lost.

## Why do you want this role?
<!-- triggers: why are you interested, what drew you to us, why this company, why here -->

Two reasons. The first is the problem shape: you're solving for the same class
of trust and reliability questions I've spent my career on, but at a scale where
the edge cases are constant rather than occasional.

The second is that your team publishes its incident reviews. That signals a
culture that treats failure as information rather than embarrassment, and that's
rarer than it should be.

## What's your biggest weakness?
<!-- triggers: what do you struggle with, area for improvement, what would your manager say you need to work on -->

I over-index on getting the model right before shipping. On a migration project
last year I spent three weeks on a data model that a prototype would have
answered in three days.

What I changed is a rule for myself: if a design decision is reversible, I ship
the simple version and let real usage tell me. If it isn't reversible, then the
three weeks are justified. Sorting decisions by reversibility rather than by how
interesting they are has been the fix.

## Tell me about a time you disagreed with your manager
<!-- triggers: conflict with your boss, pushed back on leadership, disagreement at work -->

My director wanted to ship a payments retry feature on a fixed date tied to a
partner announcement. My read was that the idempotency handling wasn't ready and
we risked double-charging a small number of customers.

I put together the actual numbers rather than arguing from principle: roughly
four hundred affected transactions at our then-current volume, and what the
support and chargeback cost would look like. We agreed to ship a scoped version
to ten percent of traffic on the announcement date and hold the full rollout two
more weeks.

The thing I'd repeat is bringing a quantified alternative rather than an
objection. The thing I'd change is raising it two weeks earlier — I had the
concern well before I did the analysis.

## Where do you see yourself in five years?
<!-- triggers: long term goals, career plans, what's next for you, ambitions -->

Running a product area rather than a single product — the layer where you're
setting the strategy and building the team that executes it, not writing every
spec yourself.

I'm deliberately not attached to a title. What I want is to still be close
enough to the actual product that I could sit in a customer call and understand
every word of it.

## Do you have any questions for us?
<!-- triggers: what questions do you have, anything you want to ask, questions for me -->

Three. What does the first ninety days look like for whoever takes this role?

When this team has shipped something that didn't work, what happened next?

And what's a decision the team made in the last year that you'd make differently
now?
