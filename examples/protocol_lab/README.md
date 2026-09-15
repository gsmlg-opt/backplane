# Protocol Lab

An independent Mix consumer used to verify `backplane_ai_protocol` public APIs without the
Backplane umbrella root configuration.

The lab starts no network service. It constructs and serializes a portable request, then observes
an independently authored TestKit Responses fixture. TestKit is a development-only dependency and
does not enter the generated production escript's runtime as a separate service.
